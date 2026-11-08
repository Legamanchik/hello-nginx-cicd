# Hello World на Nginx: Docker + CI/CD + Kubernetes

Проста сторінка «Hello, World!» на Nginx. Після кожного push у `main` вона сама збирається, перевіряється і викочується на два сервери в AWS:

- **Сервер 1 (Docker):** контейнер оновлюється скриптом `scripts/deploy.sh` через SSH.
- **Сервер 2 (k3s + Argo CD):** Kubernetes сам підтягує нову версію з git (GitOps). Тут же працює моніторинг: Prometheus, Grafana, Loki та алерти.

Обидва сервери створює Terraform.

## Як це працює

```
git push → GitHub Actions
            ├─ перевірка Dockerfile і скриптів (hadolint, shellcheck)
            ├─ збірка образу → smoke test → перевірка вразливостей (Trivy) → Docker Hub
            ├─ деплой на сервер 1 по SSH (якщо новий контейнер не піднявся, повертається старий)
            └─ коміт нового тегу в k8s/ → Argo CD бачить зміну → оновлює сервер 2
```

Кожен образ отримує тег, що дорівнює SHA коміту. Яка версія зараз працює, можна подивитися за адресою `/version.txt`.

## Що де лежить

| Шлях | Що там |
|---|---|
| `app/`, `nginx/`, `Dockerfile` | сам сайт, конфіг Nginx і образ |
| `scripts/deploy.sh` | збірка, push і деплой на сервер 1 |
| `.github/workflows/ci-cd.yml` | pipeline |
| `k8s/` | маніфести сайту для Kubernetes, збір його метрик, алерти і перевірки доступності |
| `argocd/root.yaml` | «головний» застосунок Argo CD: підтягує все з `argocd/apps/` |
| `argocd/apps/` | що розгорнуто в кластері: сайт, Prometheus + Grafana, Loki, Alloy, blackbox exporter |
| `monitoring/` | дашборд Grafana (генерується скриптом `build.py`) |
| `terraform/` | сервери, security groups, статичні IP |

## Як розгорнути у себе

Знадобляться акаунти **AWS**, **GitHub** і **Docker Hub**. Локально треба встановити `terraform`, `aws` CLI і `gh`.

**1. Увійти в AWS і GitHub**
```bash
aws login
```
```bash
gh auth login
```

**2. Створити SSH-ключ для деплою**
```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/hello-nginx-deploy
```

**3. Підняти сервери**

Спершу створіть файл `terraform/terraform.tfvars` (у git він не потрапляє) і впишіть у нього дві речі:
- свій IP: тільки з нього будуть доступні SSH, kubectl, Argo CD і Grafana на сервері 2. Дізнатися IP можна командою `curl https://checkip.amazonaws.com`;
- пароль адміністратора для Argo CD і Grafana.
```hcl
admin_cidrs    = ["ВАШ_IP/32"]
admin_password = "придумайте-пароль"
```
```bash
cd terraform && terraform init && terraform apply
```
Terraform виведе IP обох серверів і посилання на Argo CD і Grafana. Сервер 2 налаштовується ще приблизно 5 хвилин: встановлюються k3s і Argo CD, а Argo CD сам розгортає з git сайт і моніторинг.

> 💰 Сервер 1 (`t3.micro`) коштує ≈ $8 на місяць, сервер 2 (`c7i-flex.large`, 4 GB RAM для моніторингу) ≈ $74 на місяць. Без моніторингу сервер 2 можна зменшити до `k8s_instance_type = "t3.small"` (≈ $16 на місяць).

**4. Додати секрети в GitHub**

Ці команди виконуються з папки репозиторію.

Спершу збережіть ключ сервера 1, щоб CI міг безпечно підключатися по SSH:
```bash
ssh-keyscan -t ed25519 <IP_сервера_1> > ~/.ssh/hello-nginx-known_hosts
```
Потім додайте змінні й секрети:
```bash
gh variable set DOCKERHUB_USERNAME --body <логін_docker_hub>
gh variable set DEPLOY_HOST --body <IP_сервера_1>
gh secret set SSH_PRIVATE_KEY < ~/.ssh/hello-nginx-deploy
gh secret set SSH_KNOWN_HOSTS < ~/.ssh/hello-nginx-known_hosts
gh secret set DOCKERHUB_TOKEN
```
Остання команда попросить вставити токен Docker Hub. Створити його можна в *Docker Hub → Account settings → Personal access tokens*, з правами Read & Write.

Якщо ви зробили fork, замініть посилання на репозиторій (`repoURL`) у `argocd/root.yaml`, `argocd/apps/hello-nginx.yaml` і `argocd/apps/monitoring-config.yaml`.

**5. Запушити код**

Після push на вкладці *Actions* видно, як іде pipeline. Через 1–2 хвилини сайт доступний на обох серверах.

## Перевірка

| Що | Де |
|---|---|
| Сайт (Docker) | `http://<IP_сервера_1>/` |
| Сайт (Kubernetes) | `http://<IP_сервера_2>/` |
| Стан і версія | `/healthz` повертає `ok`, а `/version.txt` повертає SHA коміту |
| Argo CD | `https://<IP_сервера_2>:30443`, логін `admin` і пароль з `admin_password` (браузер попередить про самопідписаний сертифікат) |
| Grafana | `http://<IP_сервера_2>:30300`, ті самі логін і пароль |

Щоб перевірити автодеплой, змініть текст в `app/index.html` і запуште. Нова версія з'явиться на обох серверах.

## Моніторинг і логи

У Grafana відкрийте *Dashboards → **Hello Nginx***. На дашборді видно:
- **чи живі обидва сайти:** blackbox exporter кожні 30 секунд відкриває `/healthz` на сервері 1 і сервері 2;
- **час відповіді**, кількість запитів за секунду й активні з'єднання nginx (збирає sidecar `nginx-prometheus-exporter`);
- **скільки подів готово** і скільки пам'яті вони використовують;
- **HTTP-статуси** (200, 404, …) і самі **логи** nginx. Їх збирає Alloy, а зберігає Loki 3 дні.

Окрім цього дашборда, kube-prometheus-stack додає готові дашборди для сервера (node exporter) і Kubernetes.

**Алерти** описані в `k8s/monitoring.yaml`:

| Алерт | Коли спрацьовує |
|---|---|
| `HelloNginxSiteDown` | сайт не відповідає 2 хвилини |
| `HelloNginxNoReadyPods` | у Kubernetes немає жодного робочого пода |
| `HelloNginxRestarting` | контейнер перезапустився більше 3 разів за 15 хвилин |
| `HelloNginxSlow` | сайт відповідає довше 1 секунди протягом 5 хвилин |

Алерти, що спрацювали, видно на дашборді (панель *Firing alerts*) і в *Grafana → Alerting*. Щоб отримувати їх на пошту чи в Telegram, додайте receiver в Alertmanager (`alertmanager.config` у `argocd/apps/kube-prometheus-stack.yaml`).

Логи сервера 1 (Docker) зберігаються на самому сервері з ротацією (3 файли по 10 MB): `docker logs hello-nginx`.

## Корисні команди

```bash
./scripts/deploy.sh all                    # ручний деплой на сервер 1 (потрібні IMAGE_NAME, DEPLOY_HOST)
docker build -t hello . && docker run -p 8080:8080 hello   # запуск локально → http://localhost:8080
ssh ... 'docker logs -f hello-nginx'       # логи на сервері 1
ssh ... 'kubectl -n hello get pods'        # стан подів на сервері 2
ssh ... 'kubectl -n argocd get applications'   # що розгорнув Argo CD
python3 monitoring/dashboards/build.py     # перегенерувати дашборд після змін
```

## Видалити все

```bash
cd terraform && terraform destroy
```

## Якщо щось не працює

- **Деплой падає з `Permission denied`:** перевірте, що `SSH_PRIVATE_KEY` вставлений повністю.
- **`Host key verification failed`:** IP сервера змінився. Заново виконайте `ssh-keyscan` і оновіть секрет `SSH_KNOWN_HOSTS`.
- **Trivy зупинив збірку:** у базовому образі з'явилися нові вразливості. Зазвичай допомагає просто перезапустити pipeline.
- **У Grafana немає даних одразу після створення сервера:** зачекайте 2–3 хвилини, поки Argo CD розгорне моніторинг.
- **Сервер 2 не відповідає:** подивіться лог встановлення:
  ```bash
  ssh ... 'sudo cat /var/log/bootstrap-k3s.log'
  ```
