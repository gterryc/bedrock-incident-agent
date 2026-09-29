# bedrock-incident-agent

Demo para AWS Community Day (nivel 300, track Generative AI & ML): un agente de **Amazon Bedrock
AgentCore** que diagnostica solo la causa raiz de un incidente de infraestructura y explica el
porque en espanol.

El escenario se rompe en vivo con un comando. A partir de ahi, nadie toca nada: la alarma dispara,
el agente investiga con sus herramientas, y el diagnostico llega por email y por Slack.

> **Sobre AgentCore y no Bedrock Agents "Classic".** Bedrock Agents Classic dejo de aceptar cuentas
> nuevas el 30/07/2026, asi que en una cuenta sin uso previo del servicio `CreateAgent` devuelve
> `AccessDeniedException`. La orquestacion corre sobre **Amazon Bedrock AgentCore**: un
> `harness` (modelo + system prompt + herramientas) y un `gateway` que expone las Lambdas como
> herramientas MCP. Las Lambdas de diagnostico son las mismas; solo cambio el envelope de entrada.

## 🎤 La charla

Este repo es el material de una charla del **AWS Community Day Peru 2026** (3 de octubre,
track Generative AI & ML, nivel 300):

> **Diagnosticando incidentes en AWS con Bedrock Agents**
> George Terry · Cloud Engineer

| Material | |
|---|---|
| 📑 Slides en PDF | [`presentacion/build/AWSCommunityDayPeru2026_GeorgeTerry.pdf`](presentacion/build/AWSCommunityDayPeru2026_GeorgeTerry.pdf) |
| 📊 Slides en PowerPoint | [`presentacion/build/AWSCommunityDayPeru2026_GeorgeTerry.pptx`](presentacion/build/AWSCommunityDayPeru2026_GeorgeTerry.pptx) |
| 📐 Diagrama de arquitectura | [`presentacion/incidet_analyzer.drawio.png`](presentacion/incidet_analyzer.drawio.png) · [fuente editable](presentacion/incidet_analyzer.drawio) |
| 🗒️ Guion del orador | [`presentacion/guion.md`](presentacion/guion.md) |

El video de la demo se maneja por separado y no esta embebido en el deck: la charla lo
reproduce desde un archivo local. El guion de grabacion esta en
[`presentacion/guion-video-demo.md`](presentacion/guion-video-demo.md).

**Si llegaste hasta aca escaneando el QR de la sala:** lo que sigue es todo lo que hace
falta para levantar esta demo en tu propia cuenta. El deploy completo cuesta menos de
1 USD al dia. Segui con la seccion de **Requisitos**.

## 📐 Arquitectura desplegada

```
        ┌────────────┐  healthcheck /health          ┌─────────────────────┐
        │    ALB     │ ─────────────────────────────▶│  2x EC2 (nginx)     │
        │  (sg-alb)  │        TCP/80                 │  (sg-app)           │
        └────────────┘                               └─────────────────────┘
                                                            ▲
                        ▲ la regla de ingress sg-app ← sg-alb es el interruptor
                        │ `terraform apply -var="allow_healthcheck=false"` la borra
                        │
        ┌───────────────┴────────────┐
        │ CloudWatch Alarm           │  UnHealthyHostCount > 0
        │ period 60s, 1 evaluacion   │  → dispara en ~1 min
        └───────────────┬────────────┘
                        │ CloudWatch Alarm State Change
                        ▼
        ┌────────────────────────────┐
        │ EventBridge Rule           │
        └───────────────┬────────────┘
                        ▼
        ┌────────────────────────────┐        ┌──────────────────────────────┐
        │ λ invoke_agent             │───────▶│ AgentCore Harness            │
        │ arma el prompt             │        │ (Claude Sonnet + system      │
        │ InvokeHarness              │        │  prompt en espanol)          │
        │ loguea el trace completo   │◀───────└───────────────┬──────────────┘
        └───────────────┬────────────┘            MCP (SigV4) │
                        │                                     ▼
                        │                     ┌──────────────────────────────┐
                        │                     │ AgentCore Gateway            │
                        │                     │   ├─ λ tool_resource_state   │
                        │ respuesta final     │   ├─ λ tool_cloudtrail_events│
                        ▼                     │   └─ λ tool_cloudwatch_logs  │
                                              └──────────────────────────────┘
        ┌────────────────────────────┐
        │ λ notify  ──▶ SNS Topic    │
        └───────────────┬────────────┘
                        ├──────────▶ 📧 email
                        └──────────▶ λ notify_slack ──▶ 💬 Slack webhook
```

### Las tres herramientas del agente

| Gateway target | Funciones (MCP tools) | Que responde |
|---|---|---|
| `tool_resource_state` | `describe_target_health`, `describe_security_groups`, `describe_load_balancers` | ¿Cual es el estado **ahora**? ¿Existe la regla de ingress del healthcheck? |
| `tool_cloudtrail_events` | `lookup_events` | ¿Que **cambio** y quien lo cambio en la ventana previa a la alarma? |
| `tool_cloudwatch_logs` | `run_insights_query`, `list_log_groups` | ¿Hay **evidencia** en los logs? Los VPC Flow Logs muestran los `REJECT`. |

Las tres herramientas tienen todos los parametros opcionales: si el agente no los envia, las Lambdas
usan por defecto los recursos de esta demo (inyectados por Terraform como variables de entorno).
Asi el agente puede investigar sin adivinar ARNs.

El Gateway las expone como herramientas MCP. Los nombres que ve el agente van prefijados con el
target, por ejemplo `tool-resource-state___describe_target_health`; las Lambdas quitan ese prefijo
al resolver que funcion ejecutar.

## 📁 Estructura del proyecto

```
.
├── main.tf / variables.tf / output.tf / locals.tf / provider.tf
├── terraform.tfvars.example      # copiar a terraform.tfvars y completar
├── modules/
│   ├── network/                  # VPC, 2 AZs, IGW, VPC Flow Logs (sin NAT)
│   ├── alb-demo/                 # ALB, target group, 2 EC2, el SG que se rompe
│   ├── monitoring/               # alarma, EventBridge rule, AWS Budget
│   ├── agent/                    # AgentCore: gateway, targets, harness, 4 Lambdas
│   └── notifications/            # SNS + email + Lambda a Slack
├── lambdas/
│   ├── invoke_agent/             # orquestador; loguea el trace del agente
│   ├── tool_resource_state/
│   ├── tool_cloudtrail_events/
│   ├── tool_cloudwatch_logs/
│   ├── notify/                   # publica el diagnostico en SNS
│   └── notify_slack/             # SNS → webhook de Slack
├── scripts/
│   ├── check_model_access.sh     # comprueba que el modelo responde, antes de desplegar
│   ├── test_slack.sh             # prueba el webhook de Slack sin disparar la demo
│   ├── break_sg.sh               # rompe el ambiente (el momento de la demo)
│   ├── restore_sg.sh             # lo arregla, para volver a ensayar
│   ├── check_health.sh           # estado de targets y alarma
│   └── tail_trace.sh             # sigue el razonamiento del agente en terminal
└── presentacion/                 # material de la charla
    ├── guion.md                  # guion del orador, slide por slide
    ├── guion-video-demo.md       # shot list para grabar el video de la demo
    ├── incidet_analyzer.drawio   # diagrama de arquitectura (fuente y PNG)
    ├── assets/                   # codigos QR
    └── build/                    # slides en PDF y PPTX
```

## ⚙️ Requisitos

- Terraform >= 1.10 y **provider AWS >= 6.51.0** (los recursos `aws_bedrockagentcore_*` no existen antes)
- Credenciales de una cuenta sandbox. Ya **no hace falta AWS CLI para el `apply`**: al migrar a
  AgentCore desaparecio el `local-exec` que preparaba el agente. El CLI se sigue usando solo en los
  scripts de la demo (`check_health.sh`, `tail_trace.sh`)
- `bash` y `python3` (solo para los scripts de la demo)
- **Acceso al modelo de Bedrock.** La pagina *Model access* de la consola fue **retirada**: los
  modelos serverless se habilitan solos la primera vez que se invocan en la cuenta. Para los modelos
  de Anthropic, un usuario que nunca los uso puede tener que enviar **una vez** los datos de caso de
  uso. En vez de adivinar si hace falta, comprobalo:

  ```bash
  ./scripts/check_model_access.sh
  ```

  Si responde `✅`, no hay ningun paso manual pendiente. Si da `AccessDenied`, el script te dice que
  hacer: consola de Bedrock → *Model catalog* → Claude Sonnet → *Playground*, que es donde aparece el
  formulario de caso de uso.

## 🚀 Deploy

Un solo `apply` desde la raiz levanta los 5 modulos.

```bash
cp terraform.tfvars.example terraform.tfvars
# editar terraform.tfvars: notification_email y, si vas a usarlo, slack_webhook_url

# Comprobar que el modelo responde ANTES de desplegar (tarda 2 segundos)
./scripts/check_model_access.sh

terraform init
terraform plan
terraform apply
```

Tarda unos 5 minutos (el ALB y la creacion del harness son lo mas lento).

**Despues del apply, dos pasos manuales obligatorios:**

1. **Confirmar la suscripcion de email.** AWS manda un correo *"AWS Notification - Subscription
   Confirmation"*; hay que hacer click en el link o las notificaciones nunca llegan.
2. **Esperar a que los targets pasen a `healthy`.** nginx tarda ~1 minuto en instalarse:

   ```bash
   ./scripts/check_health.sh
   curl $(terraform output -raw alb_dns_name)   # debe devolver "OK"
   ```

   Si arrancas la demo antes de que esten `healthy`, la alarma dispara sola y te arruina el efecto.

## 🎬 Como correr la demo

Lo mas comodo es tener **dos terminales** proyectadas.

**Terminal A** — el trace del agente, abierto desde antes:

```bash
./scripts/tail_trace.sh
```

**Terminal B** — el resto:

```bash
# 1. Mostrar que todo esta sano
./scripts/check_health.sh
curl $(terraform output -raw alb_dns_name)

# 2. ROMPER EL AMBIENTE  ← el momento de la demo
./scripts/break_sg.sh
```

El script es un wrapper de `terraform apply -var="allow_healthcheck=false"`. Elimina la unica regla
de ingress que permite el healthcheck desde el SG del ALB. Pasa `-y` para saltear la confirmacion.

**Linea de tiempo esperada:**

| Tiempo | Que pasa | Donde se ve |
|---|---|---|
| 0s | Se borra la regla de ingress | salida de `break_sg.sh` |
| ~20s | Los 2 targets pasan a `unhealthy` | `./scripts/check_health.sh` |
| ~60-120s | La alarma pasa a `ALARM` | `./scripts/check_health.sh` |
| +2s | EventBridge invoca `invoke_agent` | Terminal A |
| +5-60s | El agente razona y llama sus herramientas | **Terminal A** ← lo interesante |
| al final | Diagnostico por email y Slack | bandeja de entrada / canal |

Mientras corre, en la Terminal A se ve el ciclo completo del agente:

```
------------------------------------------------------------------------------
[PASO 1] RAZONAMIENTO DEL AGENTE
------------------------------------------------------------------------------
La alarma reporta 2 targets unhealthy. Antes de buscar causas
confirmo las reglas vigentes del security group de los targets.

------------------------------------------------------------------------------
[PASO 2] LLAMADA A HERRAMIENTA
------------------------------------------------------------------------------
Herramienta : tool-resource-state___describe_security_groups
Argumentos  : {
  "security_group_ids": "sg-0a1b2c3d,sg-0e4f5a6b"
}
Fin de mensaje. stopReason=tool_use

------------------------------------------------------------------------------
[PASO 3] RESPUESTA DE LA HERRAMIENTA
------------------------------------------------------------------------------
{
  "security_groups": [
    {
      "group_id": "sg-0e4f5a6b",
      "group_name": "bedrock-incident-agent-app-sg",
      "ingress_rules": []
    }
  ]
}
```

El `ingress_rules: []` proyectado en pantalla es el momento en que se ve la causa raiz.

El trace se arma en la Lambda `invoke_agent`, no en la consola. `InvokeHarness` devuelve un event
stream tipado estilo Converse (`messageStart` / `contentBlockStart` / `contentBlockDelta` /
`contentBlockStop` / `messageStop` / `metadata`). El contenido llega troceado en deltas, asi que la
Lambda los acumula por `contentBlockIndex` y imprime cada bloque entero al recibir su
`contentBlockStop`; si no, el log tendria una linea por token.

El `stopReason` de cada mensaje tambien se loguea, y el diagnostico final es el texto del mensaje
que cierra con `end_turn` — por eso un comentario intermedio del agente no se confunde con su
conclusion. Si el agente corta por `max_iterations_exceeded` o `timeout_exceeded`, queda un WARNING
en el log y se notifica igual lo que alcanzo a producir.

### Volver a ensayar

```bash
./scripts/restore_sg.sh     # los targets vuelven a healthy en ~20s
```

Espera a que la alarma vuelva a `OK` antes de romper otra vez: si sigue en `ALARM`, no hay
transicion de estado y EventBridge no dispara.

### Ensayar el agente sin romper nada

```bash
aws lambda invoke \
  --function-name "$(terraform output -raw invoke_agent_function_name)" \
  --cli-binary-format raw-in-base64-out \
  --payload '{"prompt":"Revisa el estado del target group y decime si esta sano."}' \
  /dev/stdout
```

`invoke_agent` acepta `{"prompt": "..."}` para invocaciones manuales, sin necesidad de un evento
de EventBridge.

## 💬 Configurar Slack (opcional)

Se usa un **Incoming Webhook**, no un bot token: es lo mas simple y no hay scopes que administrar.
El webhook queda atado a un canal concreto en el momento de instalarlo.

1. Entra a <https://api.slack.com/apps> → **Create New App** → **From scratch**.
   Ponle un nombre (por ejemplo `Bedrock Incident Agent`) y elige tu workspace.
2. En el menu lateral → **Incoming Webhooks** → activa **Activate Incoming Webhooks**.
3. Abajo → **Add New Webhook to Workspace** → elige el canal → **Allow**.
4. Copia la URL que queda (`https://hooks.slack.com/services/T.../B.../...`).

> Si el canal es **privado**, primero invita la app desde el canal con `/invite @Bedrock Incident Agent`,
> o no aparecera en la lista del paso 3.

Esa URL **es la credencial**: quien la tenga puede publicar en ese canal. No se comparte ni se
versiona. Va en `terraform.tfvars`, que esta en `.gitignore`:

```hcl
slack_webhook_url = "https://hooks.slack.com/services/T000/B000/xxxxxxxx"
```

```bash
terraform apply
./scripts/test_slack.sh     # verifica el envio sin disparar la demo ni mandar emails
```

`test_slack.sh` invoca la Lambda `notify_slack` con un evento SNS sintetico. Si ves el mensaje en el
canal, esta listo.

**Costo: cero, de los dos lados.** Los Incoming Webhooks de Slack son gratuitos en todos los planes,
incluido el Free. Del lado de AWS, el envio son invocaciones de Lambda y publicaciones de SNS: el
free tier cubre 1M de invocaciones y 1M de publicaciones al mes, y una demo usa un punado. Lo unico
con costo real del proyecto sigue siendo el ALB.

**Si no configuras Slack no se rompe nada**: con `slack_webhook_url` vacio la Lambda loguea el
mensaje y termina bien, y la notificacion por email llega igual.

## 🧹 Cleanup

```bash
terraform destroy
```

Borra todo, incluidos ALB, EC2, agente y log groups. **Corrélo al terminar la charla**: el ALB es
el unico recurso con costo por hora relevante (~0.025 USD/h) y el resto queda practicamente en cero.

Si `destroy` falla en el gateway porque todavia tiene targets asociados, reintenta: Terraform los
borra en orden y el segundo intento pasa.

Verificar que no quedo nada:

```bash
terraform state list        # debe salir vacio
```

## 💰 Costo

Pensado para una cuenta personal:

- **Sin NAT Gateway** (~32 USD/mes ahorrados). Los targets viven en subnets publicas con IP publica
  para poder instalar nginx via IGW. Las subnets privadas se crean igual, pero quedan sin uso.
- **Sin CloudTrail Trail propio**: se consulta el Event History de 90 dias con `LookupEvents`, que no
  cuesta nada y no necesita bucket S3 ni tabla de Athena.
- 2x `t3.micro`, retencion de logs de **1 dia**, `deregistration_delay` de 10s.
- **AWS Budget** de 20 USD mensuales con alerta al 80% del gasto real y al 100% del proyectado
  (se incluyo porque es un solo recurso y no complica el deploy; desactivable con
  `enable_budget = false`).

Dejandolo levantado un dia entero: menos de 1 USD, dominado por el ALB.

## 🔐 Seguridad

- `slack_webhook_url` es `sensitive` y su default es vacio: nada hardcodeado, y el `apply` funciona
  sin Slack (la Lambda loguea el mensaje y termina bien).
- `terraform.tfvars` esta en `.gitignore`; se versiona solo `terraform.tfvars.example`.
- Cada Lambda tiene su **propio rol**, y cada rol solo puede escribir en **su** log group.
  Donde la API de AWS lo soporta, los permisos estan acotados al recurso concreto
  (`logs:StartQuery` a los log groups de la demo, `bedrock-agentcore:InvokeHarness` al harness,
  `lambda:InvokeFunction` del gateway acotado a las 3 Lambdas herramienta, `sns:Publish` al topic). Las acciones `Describe*` de EC2/ELBv2 y `cloudtrail:LookupEvents` **no admiten permisos a
  nivel de recurso**, asi que ahi el `Resource` es `*`, acotado por una lista de acciones de solo
  lectura. Esta comentado en el codigo.
- Los roles de gateway y harness tienen condiciones `aws:SourceAccount` y `aws:SourceArn` contra el
  problema del *confused deputy*, y las Lambdas de tools solo aceptan invocaciones de **este** gateway.
- El Gateway usa `authorizer_type = "AWS_IAM"`: el harness se autentica con SigV4 usando su rol de
  ejecucion. No hace falta montar un pool de Cognito ni un proveedor OAuth solo para que el agente
  pueda llamar a sus propias herramientas.
- Las EC2 usan IMDSv2 obligatorio, volumen cifrado y **no tienen SSH**: para depurar se entra por
  SSM Session Manager.

## 🔧 Troubleshooting

**El harness falla al invocar el modelo, o el modelo no existe.**
Corre `./scripts/check_model_access.sh` primero: distingue entre las dos causas.

Si es `AccessDenied`, falta el formulario de caso de uso de Anthropic (una vez por cuenta) o hay una
policy de IAM/SCP bloqueando `bedrock:InvokeModel`. Si es `ValidationException`, el inference profile
no esta disponible en tu region; mira que tenes y cambia la variable:

```bash
aws bedrock list-inference-profiles --region us-east-1 \
  --query 'inferenceProfileSummaries[?contains(inferenceProfileId,`sonnet`)].inferenceProfileId'
```

```hcl
# terraform.tfvars
bedrock_model_id = "anthropic.claude-3-5-sonnet-20240620-v1:0"   # fallback on-demand
```

**La alarma disparo sola apenas termino el apply.**
nginx todavia no estaba arriba. Espera a que `check_health.sh` muestre los targets `healthy`, la
alarma vuelve sola a `OK`.

**Rompi el SG pero no paso nada.**
Revisa que la alarma haya *cambiado* de estado (`./scripts/check_health.sh`). EventBridge escucha la
transicion a `ALARM`; si ya estaba en `ALARM`, no hay evento nuevo.

**El agente responde pero dice que no encontro cambios en CloudTrail.**
CloudTrail puede tardar hasta 15 minutos en indexar un evento en el Event History. El resto del
diagnostico (estado del SG y `REJECT` en los flow logs) igual alcanza para la causa raiz; la
herramienta devuelve una nota explicando esta latencia para que el agente no invente.

**El primer `terraform apply` falla en el harness con "inconsistent result after apply".**
Ver el punto 3 de la seccion anterior. Si te pasa con una version del modulo que no declare
`environment_variables = {}`, agregalo y volve a aplicar: Terraform reemplaza el harness tainted y
sigue con el resto.

**El diagnostico llega cortado, sin las cuatro secciones.**
El agente agoto `max_iterations`. En el log de `invoke_agent` vas a ver
`stopReason=max_iterations_exceeded` y un WARNING. Sube `agent_max_iterations` en el modulo del
agente. Se notifica igual lo que alcanzo a producir, a proposito: en vivo es peor un silencio.

**El agente dice que una herramienta tuvo "un problema tecnico".**
Mira el log de esa Lambda (`/aws/lambda/<prefijo>-tool-*`). Si ves `Runtime.MarshalError`, la
funcion devolvio un tipo que no es JSON nativo; ver el punto 2 de la seccion anterior.

**No llega el email.**
¿Confirmaste la suscripcion de SNS? Revisa tambien spam.

**La Lambda `invoke_agent` falla con `UnknownServiceError: bedrock-agentcore`.**
El boto3 que trae el runtime de Lambda es anterior a AgentCore. La funcion lo detecta y lo dice con
ese texto. Se arregla adjuntando una layer con un boto3 reciente:

```bash
mkdir -p /tmp/layer/python && pip install -t /tmp/layer/python boto3 --upgrade
cd /tmp/layer && zip -qr boto3.zip python
aws lambda publish-layer-version --layer-name boto3-reciente \
  --zip-file fileb:///tmp/layer/boto3.zip --compatible-runtimes python3.12
# y luego referenciar el ARN resultante en `layers` de aws_lambda_function.invoke_agent
```

Para saber si hace falta antes de romper nada:

```bash
aws lambda invoke --function-name "$(terraform output -raw invoke_agent_function_name)" \
  --cli-binary-format raw-in-base64-out \
  --payload '{"prompt":"Decime en una linea si estas operativo."}' /dev/stdout
```

### Que esta verificado contra los modelos de AWS y que no

Las formas de los recursos Terraform salen del schema del binario del provider AWS, y los
validadores del propio provider fijaron dos cosas: los nombres de gateway target van con guion
medio, y `authorizer_type` acepta `[CUSTOM_JWT AWS_IAM NONE AUTHENTICATE_ONLY]`.

La llamada de `invoke_agent` esta validada contra el modelo de servicio de botocore: `InvokeHarness`
existe en el plano de datos `bedrock-agentcore`, toma `harnessArn` + `runtimeSessionId` (minimo 33
caracteres, un UUID4 tiene 36) + `messages`, y devuelve `stream` como event stream.

Contra la cuenta real se comprobo que `us.anthropic.claude-sonnet-4-5-20250929-v1:0` responde a
`bedrock-runtime converse` en `us-east-1`, y que `bedrock-agentcore-control` lista gateways,
harnesses y runtimes sin error: el servicio esta disponible y no hace falta ningun paso manual de
habilitacion de modelo. **`terraform plan` corre limpio contra la cuenta: 77 recursos a crear, 0
errores.**

#### Cuidado con los nombres si cambias `project_name`

Los tres recursos de AgentCore validan su nombre con reglas **distintas e incompatibles**:

| Recurso | Regla | Guion medio | Guion bajo |
|---|---|:---:|:---:|
| `harness_name` | empieza con letra, `a-zA-Z0-9_`, max 40 | ❌ | ✅ |
| `gateway.name` | `^([0-9a-zA-Z][-]?){1,100}$` | ✅ | ❌ |
| `gateway_target.name` | `a-zA-Z0-9-`, max 50 | ✅ | ❌ |

Por eso el modulo deriva dos formas del mismo prefijo (`local.harness_name` y `local.gateway_name`).
Y por eso `project_name` tiene dos `validation` en la raiz: asi el error sale al principio y en
castellano, en vez de aparecer como un regex del provider a mitad del apply.

Ademas, el provider solo comprueba estos validadores en `plan` cuando el valor viene de una
variable; con literales los detecta ya en `validate`. Correr `terraform plan` antes del apply no es
opcional aqui.

**El flujo completo se ejecuto contra la cuenta real de punta a punta**: alarma -> invoke_agent ->
InvokeHarness -> gateway -> las 3 Lambdas herramienta -> notify -> SNS, en ~45 segundos, con las
cuatro secciones del diagnostico en espanol y el evento de CloudTrail identificando quien quito la
regla. Ya no queda nada sin verificar; `bedrock-agentcore:InvokeGateway` del rol del harness
resulto ser correcta.

#### Cuatro cosas que solo se descubren desplegando

**1. Invocar el harness exige DOS acciones IAM, no una.** La Lambda llama a la operacion
`InvokeHarness`, pero el permiso no se llama igual: hacen falta **`bedrock-agentcore:InvokeAgentRuntime`
y `bedrock-agentcore:InvokeHarness`**, ambas sobre el ARN del harness. El servicio las evalua en
cascada, asi que concediendo solo una el `AccessDenied` nombra la otra y parece que te falta esa.
No es deducible del modelo de servicio de botocore.

**2. Lo que devuelve una Lambda herramienta tiene que ser JSON nativo.** El runtime de Lambda
serializa el valor devuelto con `json.dumps` **sin** `default`, y varias APIs de AWS devuelven
objetos `datetime` (el `EventTime` de CloudTrail, por ejemplo). Sin normalizar, la invocacion muere
con `Runtime.MarshalError` y el agente solo ve un fallo opaco: en la primera corrida real el agente
reporto *"CloudTrail tiene un problema tecnico"* y entrego el diagnostico sin saber quien habia
hecho el cambio. Las tres tools normalizan con `json.loads(json.dumps(result, default=str))` antes
de devolver.

Esto no pasaba en Bedrock Agents Classic porque alli el handler devolvia un **string** ya
serializado dentro del sobre `functionResponse`; al pasar a AgentCore se devuelve el objeto crudo.

**3. El harness necesita `environment_variables = {}` declarado explicitamente.** Aunque no uses
variables de entorno. Es un atributo `optional` y **sensible**; el servicio devuelve `{}` y el
provider no lo normaliza contra el `null` de una config que no lo declara. El resultado es que el
**primer apply falla**:

```
Error: Provider produced inconsistent result after apply
  .environment_variables: inconsistent values for sensitive attribute
```

Al ser sensible, Terraform no puede mostrar el diff y solo dice que es un bug del provider. El
recurso si se crea en AWS (queda `READY`), pero Terraform lo marca **tainted**, asi que el apply
siguiente lo reemplaza. Esto **solo ocurre al crear**: en un update in-place no aparece, asi que es
facil no verlo si vienes iterando sobre un harness que ya existe.

De los 13 atributos del harness, `environment_variables` es el unico `optional` sin `computed`
(fuera de `tags`, que cubre `default_tags`). Los demas (`allowed_tools`, `truncation`,
`max_iterations`, `max_tokens`, `timeout_seconds`) son `optional+computed` y toleran el null.

**4. `max_iterations` 12 era corto.** En la primera corrida real el agente agoto el tope
investigando flow logs y termino con `max_iterations_exceeded`, sin llegar a conclusion. El default
es 25, y el system prompt le pide cerrar en cuanto tenga evidencia suficiente. Con eso la
investigacion completa tarda ~45 s.

### Por que ya no hay un `local-exec`

En Bedrock Agents Classic habia que ejecutar `aws bedrock-agent prepare-agent` despues de crear los
action groups, y luego versionar un alias. El recurso del agente no podia depender de sus propios
action groups sin generar un ciclo, asi que hacia falta un `terraform_data` con `local-exec`.

AgentCore no tiene ese paso: el harness queda invocable en cuanto termina de crearse, y las
herramientas se resuelven en runtime a traves del gateway. Eso elimino el `local-exec`, el alias, el
versionado y la dependencia de AWS CLI en el `apply`.

## 📄 Documentación generada automáticamente

<!-- BEGIN_TF_DOCS -->
#### Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement_terraform) | >= 1.10.0 |
| <a name="requirement_archive"></a> [archive](#requirement_archive) | >=2.4.0 |
| <a name="requirement_aws"></a> [aws](#requirement_aws) | >= 6.51.0 |

#### Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider_aws) | 6.65.0 |

#### Resources

| Name | Type |
|------|------|

#### Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_allow_healthcheck"></a> [allow_healthcheck](#input_allow_healthcheck) | Interruptor de la demo. En true el SG del target permite el healthcheck desde el SG del ALB. En false esa regla de ingress se elimina y el target group se pone unhealthy. | `bool` | `true` | no |
| <a name="input_aws_region"></a> [aws_region](#input_aws_region) | AWS region donde se despliega la demo. Bedrock AgentCore debe estar disponible aqui. | `string` | `"us-east-1"` | no |
| <a name="input_bedrock_model_id"></a> [bedrock_model_id](#input_bedrock_model_id) | Modelo base del agente de AgentCore. Por defecto el inference profile cross-region de Claude Sonnet 4.5. Ver la seccion de troubleshooting del README si tu cuenta no tiene acceso a este modelo. | `string` | `"us.anthropic.claude-sonnet-4-5-20250929-v1:0"` | no |
| <a name="input_budget_limit_usd"></a> [budget_limit_usd](#input_budget_limit_usd) | Limite mensual del budget en USD. | `string` | `"20"` | no |
| <a name="input_cloudtrail_lookback_minutes"></a> [cloudtrail_lookback_minutes](#input_cloudtrail_lookback_minutes) | Ventana por defecto (en minutos, hacia atras desde el disparo de la alarma) que el agente usa para buscar cambios en CloudTrail. | `number` | `60` | no |
| <a name="input_enable_budget"></a> [enable_budget](#input_enable_budget) | Crea un AWS Budget mensual con alerta por email. | `bool` | `true` | no |
| <a name="input_instance_type"></a> [instance_type](#input_instance_type) | Tipo de instancia de los targets EC2. t3.micro es suficiente para servir un healthcheck. | `string` | `"t3.micro"` | no |
| <a name="input_log_retention_days"></a> [log_retention_days](#input_log_retention_days) | Retencion de todos los log groups de la demo. Se deja baja a proposito para minimizar costo. | `number` | `1` | no |
| <a name="input_notification_email"></a> [notification_email](#input_notification_email) | Email que recibe la notificacion final del agente via SNS. Requiere confirmar la suscripcion desde el correo. | `string` | n/a | yes |
| <a name="input_project_name"></a> [project_name](#input_project_name) | Prefijo para nombrar todos los recursos de la demo. | `string` | `"bedrock-incident-agent"` | no |
| <a name="input_slack_webhook_url"></a> [slack_webhook_url](#input_slack_webhook_url) | Incoming Webhook de Slack. Se deja vacio por defecto: si esta vacio, la Lambda notify_slack loguea el mensaje y no intenta enviarlo. | `string` | `""` | no |
| <a name="input_vpc_cidr"></a> [vpc_cidr](#input_vpc_cidr) | CIDR de la VPC de la demo. | `string` | `"10.42.0.0/16"` | no |

#### Outputs

| Name | Description |
|------|-------------|
| <a name="output_agentcore_gateway_id"></a> [agentcore_gateway_id](#output_agentcore_gateway_id) | ID del Gateway MCP que expone las 3 herramientas. |
| <a name="output_agentcore_gateway_url"></a> [agentcore_gateway_url](#output_agentcore_gateway_url) | Endpoint MCP del gateway. |
| <a name="output_agentcore_harness_id"></a> [agentcore_harness_id](#output_agentcore_harness_id) | ID del harness de AgentCore. |
| <a name="output_alarm_name"></a> [alarm_name](#output_alarm_name) | Nombre de la alarma de CloudWatch que dispara el flujo. |
| <a name="output_alb_dns_name"></a> [alb_dns_name](#output_alb_dns_name) | URL del ALB. Sirve para comprobar a mano que la app responde (y que deja de responder al romper el SG). |
| <a name="output_app_security_group_id"></a> [app_security_group_id](#output_app_security_group_id) | SG de los targets: es el recurso que se modifica para provocar el incidente. |
| <a name="output_invoke_agent_function_name"></a> [invoke_agent_function_name](#output_invoke_agent_function_name) | Nombre de la Lambda invoke_agent, util para invocarla a mano al ensayar. |
| <a name="output_invoke_agent_log_group"></a> [invoke_agent_log_group](#output_invoke_agent_log_group) | Log group donde se imprime el trace de razonamiento del agente. |
| <a name="output_sns_topic_arn"></a> [sns_topic_arn](#output_sns_topic_arn) | Topic SNS con las notificaciones finales. |
| <a name="output_tail_trace_command"></a> [tail_trace_command](#output_tail_trace_command) | Comando listo para seguir el trace del agente en vivo durante la demo. |
| <a name="output_target_group_arn"></a> [target_group_arn](#output_target_group_arn) | ARN del target group vigilado por la alarma. |
<!-- END_TF_DOCS -->

---

## 🪪 Licencia

MIT © 2025 George Terry
