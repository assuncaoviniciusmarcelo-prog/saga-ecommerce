# Decisões Arquiteturais: Saga de Compra

Documento técnico complementar ao [README](../README.md). Segue o formato de ADRs (contexto, decisão, consequências).

## ADR-001: Saga por Orquestração

- **Contexto:** fluxo de 3 etapas com compensação em ordem inversa, tendência de crescimento (antifraude, frete, fidelidade).
- **Decisão:** orquestrador dedicado que mantém o estado da saga e emite comandos.
- **Consequências:** (+) fluxo legível, estado consultável, evolução simples. (-) componente adicional a operar; risco de concentrar regras de negócio.
- **Mitigações:** orquestrador stateless com estado em banco, múltiplas réplicas, e restrição de escopo a sequenciamento.

## ADR-002: Mensageria assíncrona com Transactional Outbox e Inbox

- **Decisão:** cada serviço grava o evento/comando na tabela `outbox` na mesma transação local do estado de negócio. Um relay (polling ou CDC) publica no broker. Consumidores usam `inbox`/`processed_messages` para deduplicação.
- **Garantia:** entrega *at-least-once* com efeito *effectively-once*.
- **Risco mitigado:** divergência entre estado gravado e evento publicado (dual write).

## ADR-003: Contrato de mensagens

Todo comando e evento carrega:

| Campo | Uso |
|---|---|
| `message_id` (UUID) | Deduplicação no consumidor |
| `saga_id` | Correlação; usado como `correlation_id` em logs e traces |
| `order_id` | Chave de negócio |
| `type`, `version` | Roteamento e evolução de schema |
| `occurred_at` | Auditoria e tratamento de mensagens fora de ordem |
| `payload` | Dados da etapa |

Particionamento por `order_id` (ou `saga_id`) para preservar ordem por pedido.

## Comandos e eventos

| Direção | Mensagem | Origem → Destino |
|---|---|---|
| Comando | `ReserveStock` / `ReleaseStock` | Orquestrador → Inventory |
| Comando | `ProcessPayment` / `RefundPayment` | Orquestrador → Payment |
| Comando | `ApproveOrder` / `CancelOrder` | Orquestrador → Order |
| Evento | `OrderCreated` | Order → Orquestrador |
| Evento | `StockReserved` / `StockRejected` / `StockReleased` | Inventory → Orquestrador |
| Evento | `PaymentApproved` / `PaymentRefused` / `PaymentRefunded` | Payment → Orquestrador |
| Evento | `OrderApproved` / `OrderCanceled` | Order → Orquestrador |

## Idempotência

- **Consumidor:** insert em `processed_messages (message_id, consumer)` com `UNIQUE`, na mesma transação do efeito. Violação de unicidade significa duplicata: ACK e descarte.
- **Chaves de negócio:** `UNIQUE (order_id)` em reservas e `UNIQUE (saga_id, step)` em pagamentos, como segunda linha de defesa.
- **Entrada da API:** cabeçalho `Idempotency-Key` em `POST /orders` evita pedidos duplicados por duplo clique ou retry do cliente.
- **Gateway externo:** `Idempotency-Key = saga_id + step` em toda chamada de cobrança.
- **Compensações** também são idempotentes: `ReleaseStock` repetido não libera estoque duas vezes.

## Tabela de controle da saga (`saga_instance`)

| Campo | Função |
|---|---|
| `saga_id` (PK), `order_id` | Identificação |
| `state` | STARTED, STOCK_RESERVED, PAYMENT_APPROVED, COMPLETED, COMPENSATING, COMPENSATED, FAILED |
| `current_step`, `payload` | Retomada da saga |
| `retry_count`, `deadline_at` | Retry e timeout |
| `version` | Lock otimista contra concorrência |
| `created_at`, `updated_at` | Auditoria e detecção de sagas paradas |

Transições só são aplicadas se compatíveis com o estado atual (ver [`saga-state-machine.mmd`](../diagrams/saga-state-machine.mmd)); mensagens incompatíveis são registradas e ignoradas.

## Riscos mitigados

| Cenário | Risco | Tratamento |
|---|---|---|
| Mensagem duplicada | Reserva ou cobrança em dobro | Inbox por `message_id` + chaves únicas de negócio |
| Timeout em `ReserveStock` ou resposta perdida | Saga parada | Scheduler varre `deadline_at < now` e reenvia com backoff; consumidor idempotente absorve |
| Timeout ambíguo no gateway | Cobrança feita sem resposta | Não compensar às cegas: consultar o gateway pela idempotency key e só então emitir `PaymentApproved` ou `PaymentRefused` |
| Mensagens fora de ordem (`ReleaseStock` antes de `ReserveStock`) | Reserva fantasma | Inventory grava *tombstone* de cancelamento e ignora o `ReserveStock` tardio |
| `PaymentApproved` após saga em COMPENSATING | Cliente cobrado sem pedido | Orquestrador emite `RefundPayment` |
| Falha ao publicar após commit | Estado e evento divergem | Transactional Outbox |
| Falha na compensação | Inconsistência permanente | Compensações retentáveis sem limite de tempo e idempotentes; alerta após N falhas |
| Queda do orquestrador | Saga interrompida | Estado persistido; outra réplica retoma pelo scheduler |
| Dois orquestradores processando a mesma saga | Comandos duplicados | Lock otimista (`version`) + consumidores idempotentes |

## Dead-Letter Queues (DLQ)

- Uma DLQ por fila de consumo (`inventory.commands.dlq`, `payment.commands.dlq`, `order.commands.dlq`, `saga.events.dlq`).
- Vai para a DLQ: mensagem que esgotou os retries, falhou na desserialização/validação de schema (*poison message*) ou violou invariantes de negócio sem tratamento possível.
- A mensagem preserva `message_id`, `saga_id`, cabeçalhos originais, motivo da falha e contagem de tentativas.
- Alertas por profundidade e idade da DLQ; painel de operação.
- **Redrive** controlado: reprocessamento manual ou automatizado após correção. A idempotência torna o reprocessamento seguro.
- Saga cuja mensagem foi para a DLQ é marcada `FAILED` após o `deadline` final e entra na fila de intervenção manual.

## Estratégias de resiliência

| Mecanismo | Onde | Configuração de referência |
|---|---|---|
| **Retry** com backoff exponencial e jitter | Consumidores e chamadas ao gateway | Até 5 tentativas; somente erros transitórios (5xx, timeout, rede). Erros de negócio (ex.: cartão recusado) não são reenviados |
| **Circuit Breaker** | Payment → Gateway | Abre ao passar de ~50% de falhas em janela deslizante; *half-open* com chamadas de prova. Com o circuito aberto, a saga aguarda até o `deadline` e então compensa |
| **Timeout** em toda chamada síncrona | Payment → Gateway, API | Valores explícitos e menores que o `deadline` da etapa |
| **Bulkhead** | Payment | Pool de threads/conexões isolado para o gateway |
| **Deadline por etapa** | `saga_instance.deadline_at` | Ex.: 30 s reserva, 2 min pagamento; ao vencer: retry, depois compensação |
| **Escalabilidade horizontal** | Todos | Consumidores em *consumer groups*; orquestrador stateless |

## Observabilidade

- `correlation_id = saga_id` em logs, traces (OpenTelemetry) e métricas.
- Métricas: sagas por estado, tempo até COMPLETED, taxa de compensação, idade da DLQ, retries por etapa, sagas com `deadline_at` vencido.
- Alertas: saga em COMPENSATING ou STARTED além do esperado, `FAILED > 0`, DLQ não vazia.

## Consistência eventual: semântica para o negócio

O pedido é exibido como **PENDING** enquanto a saga corre e muda para **APPROVED** ou **CANCELED** ao final. O cliente é informado do estado intermediário (tela de acompanhamento, notificação). A reserva de estoque é temporária e expira se a saga não avançar.

## Trade-offs e pontos em aberto

- Orquestrador é componente crítico: exige alta disponibilidade e monitoramento.
- Isolamento (o "I" do ACID) não existe: outras leituras podem ver estado intermediário. Mitigado com semântica de reserva e estados explícitos.
- Escolha do broker (Kafka vs. RabbitMQ) pode ser decidida em ADR própria conforme volume, ordenação e retenção.
