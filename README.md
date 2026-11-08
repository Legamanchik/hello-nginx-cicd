# Hello World на Nginx: Docker + CI/CD + Kubernetes

Проста сторінка «Hello, World!» на Nginx. Після кожного push у `main` вона сама збирається, перевіряється і викочується на два сервери в AWS:

- **Сервер 1 (Docker):** контейнер оновлюється скриптом `scripts/deploy.sh` через SSH.
- **Сервер 2 (k3s + Argo CD):** Kubernetes сам підтягує нову версію з git (GitOps).

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
| `k8s/` | маніфести для Kubernetes (Deployment, Service, Ingress) |
| `argocd/application.yaml` | що саме Argo CD має синхронізувати |
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

Спершу створіть файл `terraform/terraform.tfvars` і впишіть у нього свій IP. Тільки з цієї адреси будуть доступні SSH, kubectl і Argo CD на сервері 2. Свій IP можна дізнатися командою `curl https://checkip.amazonaws.com`.
```hcl
admin_cidrs = ["ВАШ_IP/32"]
```
```bash
cd terraform && terraform init && terraform apply
```
Terraform виведе IP обох серверів і посилання на Argo CD. Сервер 2 налаштовується ще приблизно 5 хвилин після цього.

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

У `argocd/application.yaml` вкажіть посилання на свій репозиторій.

**5. Запушити код**

Після push на вкладці *Actions* видно, як іде pipeline. Через 1–2 хвилини сайт доступний на обох серверах.

## Перевірка

| Що | Де |
|---|---|
| Сайт (Docker) | `http://<IP_сервера_1>/` |
| Сайт (Kubernetes) | `http://<IP_сервера_2>/` |
| Стан і версія | `/healthz` повертає `ok`, а `/version.txt` повертає SHA коміту |
| Argo CD | `https://<IP_сервера_2>:30443`, логін `admin` (браузер попередить про самопідписаний сертифікат) |

Пароль від Argo CD:
```bash
ssh -i ~/.ssh/hello-nginx-deploy ec2-user@<IP_сервера_2> \
  "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
```

Щоб перевірити автодеплой, змініть текст в `app/index.html` і запуште. Нова версія з'явиться на обох серверах.

## Корисні команди

```bash
./scripts/deploy.sh all                    # ручний деплой на сервер 1 (потрібні IMAGE_NAME, DEPLOY_HOST)
docker build -t hello . && docker run -p 8080:8080 hello   # запуск локально → http://localhost:8080
ssh ... 'docker logs -f hello-nginx'       # логи на сервері 1
ssh ... 'kubectl -n hello get pods'        # стан подів на сервері 2
```

## Видалити все

```bash
cd terraform && terraform destroy
```

## Якщо щось не працює

- **Деплой падає з `Permission denied`:** перевірте, що `SSH_PRIVATE_KEY` вставлений повністю.
- **`Host key verification failed`:** IP сервера змінився. Заново виконайте `ssh-keyscan` і оновіть секрет `SSH_KNOWN_HOSTS`.
- **Trivy зупинив збірку:** у базовому образі з'явилися нові вразливості. Зазвичай допомагає просто перезапустити pipeline.
- **Сервер 2 не відповідає:** подивіться лог встановлення:
  ```bash
  ssh ... 'sudo cat /var/log/bootstrap-k3s.log'
  ```
