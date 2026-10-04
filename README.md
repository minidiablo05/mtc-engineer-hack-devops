# Kubernetes DevOps Hackathon

## О проекте

Проект представляет собой автоматизированное развёртывание веб-приложения в multi-node Kubernetes-кластере на Ubuntu 24.04.

Репозиторий содержит скрипты не только для установки прикладной инфраструктуры, но и для подготовки чистых Ubuntu-нод и создания Kubernetes-кластера через `kubeadm`.

В составе решения реализованы:

- Kubernetes-кластер: 1 control-plane + 2 worker;
- containerd;
- Calico CNI;
- MetalLB;
- Kubernetes Gateway API;
- NGINX Gateway Fabric;
- cert-manager и HTTPS;
- NGINX-приложение в 4 репликах;
- Prometheus;
- Grafana;
- Fluentd;
- Loki;
- автоматическое развёртывание;
- автоматическая проверка работоспособности.

Тестовое приложение возвращает страницу:

```html
<h1>Hello World!</h1>
```

---

# Архитектура

```text
                     Client
                       |
                    HTTPS
                       |
                  MetalLB IP
                       |
              NGINX Gateway Fabric
                       |
                 Gateway API
                       |
                   HTTPRoute
                       |
              Kubernetes Service
                       |
             +---------+---------+
             |                   |
        k8s-worker1         k8s-worker2
          nginx x2            nginx x2
             |                   |
          Fluentd             Fluentd
             +--------+----------+
                      |
                     Loki
                      |
                   Grafana
```

Мониторинг:

```text
Kubernetes
    |
    +--> kube-state-metrics
    +--> node-exporter
    +--> kubelet
    +--> control-plane metrics
              |
              v
          Prometheus
              |
              v
           Grafana
```

---

# Используемые технологии

| Компонент             | Версия                     |
| --------------------- | -------------------------- |
| Ubuntu                | 24.04 LTS                  |
| Kubernetes            | v1.35.9                    |
| containerd            | 2.x                        |
| Calico                | v3.33.0                    |
| MetalLB               | v0.16.1                    |
| NGINX Gateway Fabric  | 2.7.2                      |
| cert-manager          | v1.21.2                    |
| kube-prometheus-stack | 91.9.0                     |
| Loki Helm Chart       | 7.3.0                      |
| Loki                  | 3.6.12                     |
| Fluentd               | grafana/fluent-plugin-loki |

Версии инфраструктурных компонентов задаются в:

```text
versions.env
```

---

# Требования к стенду

Для рекомендуемой multi-node конфигурации необходимы три виртуальные или физические машины с Ubuntu 24.04.

Рекомендуемая конфигурация:

```text
Control-plane:
2 CPU
4 GB RAMlfkmit


Worker 1:
2 CPU
2-4 GB RAM

Worker 2:
2 CPU
2-4 GB RAM
```

Все машины должны:

- находиться в одной сети;
- иметь уникальные hostname;
- иметь стабильные IP-адреса;
- иметь доступ в Интернет;
- иметь сетевую связность друг с другом;
- не использовать один и тот же IP;
- иметь возможность обращаться к control-plane по TCP/6443.

Пример:

```text
k8s-control    192.168.56.10
k8s-worker1    192.168.56.11
k8s-worker2    192.168.56.12
```

Конкретные адреса могут быть другими.

---

# Структура репозитория

```text
hackathon/
├── README.md
├── deploy.sh
├── verify.sh
├── versions.env
├── cluster.env.example
├── .gitignore
│
├── scripts/
│   ├── prepare-node.sh
│   ├── init-control-plane.sh
│   └── join-worker.sh
│
├── k8s/
│   ├── app/
│   ├── gateway/
│   ├── metallb/
│   ├── tls/
│   ├── logging/
│   └── loki/
│
└── docs/
```

---

# Быстрый сценарий развёртывания

Общий порядок:

```text
Ubuntu 24.04
    ↓
prepare-node.sh
    ↓
kubeadm init
    ↓
Calico
    ↓
join-worker.sh
    ↓
3-node Kubernetes
    ↓
deploy.sh
    ↓
Gateway + TLS + Monitoring + Logging
    ↓
verify.sh
```

---

# 1. Клонирование репозитория

Репозиторий необходимо получить на control-plane и worker-нодах.

Пример:

```bash
git clone <REPOSITORY_URL>
cd hackathon
```

Разрешить запуск скриптов:

```bash
chmod +x deploy.sh
chmod +x verify.sh
chmod +x scripts/*.sh
```

---

# 2. Настройка окружения

На control-plane:

```bash
cp cluster.env.example cluster.env
nano cluster.env
```

Пример:

```bash
CONTROL_PLANE_IP=192.168.56.10

POD_CIDR=10.244.0.0/16

METALLB_POOL_START=192.168.56.200
METALLB_POOL_END=192.168.56.220

GATEWAY_HOSTNAME=hackathon.local
```

## CONTROL_PLANE_IP

IP-адрес control-plane машины:

```text
192.168.56.10
```

Он должен реально принадлежать control-plane VM.

## POD_CIDR

Сеть Kubernetes Pod:

```text
10.244.0.0/16
```

Она не должна пересекаться с сетью виртуальных машин.

Например, если VM используют:

```text
192.168.56.0/24
```

то:

```text
10.244.0.0/16
```

подходит.

## METALLB_POOL_START / METALLB_POOL_END

Необходимо выбрать свободный диапазон IP в той же локальной сети, где находятся Kubernetes-ноды.

Например:

```text
192.168.56.200-192.168.56.220
```

Эти адреса не должны:

- использоваться другими устройствами;
- входить в используемый DHCP-пул;
- совпадать с IP Kubernetes-нод.

## GATEWAY_HOSTNAME

Для локального стенда можно оставить:

```text
hackathon.local
```

---

# 3. Подготовка всех Kubernetes-нод

На каждой из трёх машин выполнить:

```bash
cd hackathon
sudo ./scripts/prepare-node.sh
```

Скрипт автоматически:

- отключает swap;
- включает необходимые kernel modules;
- включает IP forwarding;
- устанавливает containerd;
- включает `SystemdCgroup`;
- добавляет Kubernetes repository;
- устанавливает kubeadm;
- устанавливает kubelet;
- устанавливает kubectl;
- фиксирует версии Kubernetes-пакетов.

После выполнения kubelet может перезапускаться до выполнения `kubeadm init` или `kubeadm join`. Это нормальное поведение.

---

# 4. Создание control-plane

Только на control-plane:

```bash
cd hackathon
sudo ./scripts/init-control-plane.sh
```

Скрипт:

1. проверяет `cluster.env`;
2. выполняет `kubeadm init`;
3. создаёт kubeconfig;
4. устанавливает Calico;
5. использует указанный `POD_CIDR`;
6. ждёт готовности сети;
7. создаёт данные подключения worker-нод;
8. сохраняет их в `join.env`.

После завершения:

```bash
kubectl get nodes -o wide
```

Control-plane должна появиться в Kubernetes.

---

# 5. Подключение worker-нод

После создания control-plane появляется файл:

```text
join.env
```

Он содержит временный Kubernetes bootstrap token.

Файл специально добавлен в `.gitignore` и не должен попадать в Git.

Скопировать его на каждый worker.

Например:

```bash
scp join.env user@192.168.56.11:~/hackathon/join.env
scp join.env user@192.168.56.12:~/hackathon/join.env
```

На первом worker:

```bash
cd ~/hackathon
sudo ./scripts/join-worker.sh
```

На втором worker:

```bash
cd ~/hackathon
sudo ./scripts/join-worker.sh
```

После подключения проверить на control-plane:

```bash
kubectl get nodes -o wide
```

Ожидаемая структура:

```text
NAME          STATUS   ROLES
k8s-control   Ready    control-plane
k8s-worker1   Ready    <none>
k8s-worker2   Ready    <none>
```

Hostname могут отличаться.

Главное условие:

```text
STATUS = Ready
```

для всех трёх нод.

---

# 6. Развёртывание приложения и инфраструктуры

На control-plane:

```bash
cd ~/hackathon
./deploy.sh
```

Скрипт автоматически устанавливает и настраивает:

```text
MetalLB
    ↓
Gateway API CRDs
    ↓
NGINX Gateway Fabric
    ↓
cert-manager
    ↓
NGINX application
    ↓
TLS
    ↓
Gateway + HTTPRoute
    ↓
Prometheus + Grafana
    ↓
Loki
    ↓
Fluentd
```

В конце выполняются smoke-тесты.

Успешное выполнение заканчивается:

```text
DEPLOYMENT COMPLETED SUCCESSFULLY
```

и:

```text
SUCCESS
```

---

# 7. MetalLB

MetalLB используется для реализации Kubernetes `LoadBalancer` в окружении без cloud-provider.

Пул IP автоматически создаётся на основе:

```text
cluster.env
```

Проверка:

```bash
kubectl get ipaddresspool -n metallb-system
```

```bash
kubectl get l2advertisement -n metallb-system
```

Проверка speaker:

```bash
kubectl get daemonset speaker -n metallb-system
```

Количество `READY` должно соответствовать количеству Kubernetes-нод.

---

# 8. Gateway API

Проверка:

```bash
kubectl get gateway -n hackathon
```

Пример:

```text
NAME                CLASS   ADDRESS          PROGRAMMED
hackathon-gateway   nginx   192.168.56.200   True
```

Конкретный `ADDRESS` зависит от диапазона MetalLB.

Gateway IP определяется автоматически Kubernetes и не зашит в скрипт.

Проверка маршрута:

```bash
kubectl get httproute -n hackathon
```

---

# 9. HTTPS

Проверить сертификат:

```bash
kubectl get certificate -n hackathon
```

Ожидается:

```text
hackathon-tls   True
```

Получить Gateway IP:

```bash
GATEWAY_IP=$(
  kubectl get gateway hackathon-gateway \
    -n hackathon \
    -o jsonpath='{.status.addresses[0].value}'
)
```

Загрузить настройки:

```bash
source cluster.env
```

Проверить приложение:

```bash
curl -k \
  --resolve "${GATEWAY_HOSTNAME}:443:${GATEWAY_IP}" \
  "https://${GATEWAY_HOSTNAME}/"
```

Ответ должен содержать:

```html
<h1>Hello World!</h1>
```

Для тестового стенда используется self-signed сертификат, поэтому применяется `curl -k`.

---

# 10. Приложение

Проверка:

```bash
kubectl get pods -n hackathon -o wide
```

Приложение запускается в четырёх репликах.

При наличии двух worker-нод Pod'ы распределяются между ними с использованием:

```text
topologySpreadConstraints
```

Проверить Service:

```bash
kubectl get svc -n hackathon
```

---

# 11. Prometheus

Проверить Pod'ы:

```bash
kubectl get pods -n monitoring
```

Для доступа к интерфейсу:

```bash
kubectl port-forward \
  --address 0.0.0.0 \
  -n monitoring \
  svc/monitoring-kube-prometheus-prometheus \
  9090:9090
```

После этого Prometheus доступен:

```text
http://<CONTROL_PLANE_IP>:9090
```

Targets:

```text
http://<CONTROL_PLANE_IP>:9090/targets
```

Примеры PromQL:

```promql
up
```

```promql
kube_node_info
```

```promql
kube_pod_info{namespace="hackathon"}
```

```promql
count(kube_pod_info{namespace="hackathon"})
```

```promql
node_memory_MemAvailable_bytes
```

---

# 12. Grafana

Для доступа:

```bash
kubectl port-forward \
  --address 0.0.0.0 \
  -n monitoring \
  svc/monitoring-grafana \
  3000:80
```

Grafana:

```text
http://<CONTROL_PLANE_IP>:3000
```

Логин:

```text
admin
```

Получить пароль:

```bash
kubectl get secret monitoring-grafana \
  -n monitoring \
  -o jsonpath="{.data.admin-password}" \
  | base64 --decode
```

---

# 13. Централизованное логирование

Архитектура:

```text
NGINX
  ↓
Fluentd
  ↓
Loki
  ↓
Grafana
```

Fluentd работает как DaemonSet на worker-нодах и читает контейнерные журналы NGINX.

Проверить:

```bash
kubectl get daemonset fluentd -n logging
```

При двух worker-нодах ожидается:

```text
DESIRED   CURRENT   READY
2         2         2
```

Проверить Loki:

```bash
kubectl get pods -n logging
```

---

# 14. Проверка логирования

Сгенерировать запросы:

```bash
source cluster.env

GATEWAY_IP=$(
  kubectl get gateway hackathon-gateway \
    -n hackathon \
    -o jsonpath='{.status.addresses[0].value}'
)

for i in {1..5}; do
  curl -k \
    --resolve "${GATEWAY_HOSTNAME}:443:${GATEWAY_IP}" \
    "https://${GATEWAY_HOSTNAME}/"
done
```

В Grafana:

```text
Explore → Loki
```

LogQL:

```logql
{application="nginx"}
```

HTTP GET:

```logql
{application="nginx"} |= "GET"
```

---

# 15. Автоматическая проверка

После развёртывания выполнить:

```bash
./verify.sh
```

Скрипт автоматически проверяет:

- Kubernetes-ноды;
- Pod'ы приложения;
- GatewayClass;
- Gateway;
- HTTPRoute;
- TLS;
- внешний IP Gateway;
- HTTPS;
- monitoring;
- Fluentd;
- Loki.

Gateway IP определяется автоматически.

Hostname берётся из:

```text
cluster.env
```

---

# 16. Проверка повторного запуска

Развёртывание допускает повторное выполнение:

```bash
./deploy.sh
```

Kubernetes-ресурсы применяются через:

```text
kubectl apply
```

Helm-компоненты устанавливаются через:

```text
helm upgrade --install
```

Поэтому повторное выполнение не должно создавать дублирующиеся ресурсы.

После второго запуска:

```bash
./verify.sh
```

и:

```bash
source cluster.env

GATEWAY_IP=$(
  kubectl get gateway hackathon-gateway \
    -n hackathon \
    -o jsonpath='{.status.addresses[0].value}'
)

curl -k \
  --resolve "${GATEWAY_HOSTNAME}:443:${GATEWAY_IP}" \
  "https://${GATEWAY_HOSTNAME}/"
```

---

# 17. Конфигурационные файлы

## versions.env

Содержит версии инфраструктурных компонентов.

Пример:

```bash
KUBERNETES_VERSION=v1.35.9
CALICO_VERSION=v3.33.0
METALLB_VERSION=v0.16.1
NGF_VERSION=2.7.2
CERT_MANAGER_VERSION=v1.21.2
PROM_STACK_VERSION=91.9.0
LOKI_CHART_VERSION=7.3.0
```

## cluster.env

Содержит настройки конкретного стенда.

Этот файл не хранится в Git.

Создаётся из:

```bash
cp cluster.env.example cluster.env
```

## join.env

Содержит временные данные для подключения worker-нод.

Не хранится в Git.

---

# 18. Безопасность

В репозиторий не должны попадать:

```text
cluster.env
join.env
```

Особенно важно не публиковать `join.env`, поскольку он содержит Kubernetes bootstrap token.

TLS-сертификат генерируется непосредственно внутри Kubernetes через cert-manager.

---

# 19. Ограничения тестового стенда

Решение предназначено для локального hackathon/bare-metal окружения.

Используются:

- одна control-plane нода;
- self-signed TLS;
- локальный MetalLB;
- single-instance Loki;
- port-forward для административного доступа к Prometheus/Grafana.

Для production рекомендуется:

- 3 control-plane ноды;
- внешний LoadBalancer;
- внешний DNS;
- Let's Encrypt или корпоративный CA;
- PersistentVolume;
- отказоустойчивый Loki;
- NetworkPolicy;
- Secret Manager;
- CI/CD;
- резервное копирование;
- Alertmanager;
- HPA.

---

# Полная последовательность для проверяющего

На всех трёх машинах:

```bash
git clone <REPOSITORY_URL>
cd hackathon
sudo ./scripts/prepare-node.sh
```

На control-plane:

```bash
cp cluster.env.example cluster.env
nano cluster.env

sudo ./scripts/init-control-plane.sh
```

Скопировать созданный:

```text
join.env
```

на обе worker-ноды.

На каждой worker:

```bash
sudo ./scripts/join-worker.sh
```

На control-plane проверить:

```bash
kubectl get nodes
```

После появления всех нод в состоянии `Ready`:

```bash
./deploy.sh
```

Затем:

```bash
./verify.sh
```

Финальная проверка приложения:

```bash
source cluster.env

GATEWAY_IP=$(
  kubectl get gateway hackathon-gateway \
    -n hackathon \
    -o jsonpath='{.status.addresses[0].value}'
)

curl -k \
  --resolve "${GATEWAY_HOSTNAME}:443:${GATEWAY_IP}" \
  "https://${GATEWAY_HOSTNAME}/"
```

Ожидаемый результат:

```html
<h1>Hello World!</h1>
```

---

# Результат

Проект позволяет пройти полный путь:

```text
Clean Ubuntu 24.04
        ↓
containerd + Kubernetes
        ↓
multi-node kubeadm cluster
        ↓
Calico
        ↓
MetalLB
        ↓
Gateway API
        ↓
HTTPS application
        ↓
Prometheus + Grafana
        ↓
Fluentd + Loki
        ↓
Automated verification
```

Основные команды:

```bash
sudo ./scripts/prepare-node.sh
sudo ./scripts/init-control-plane.sh
sudo ./scripts/join-worker.sh
./deploy.sh
./verify.sh
```
