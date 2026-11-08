# hello-nginx: Docker + CI/CD на AWS

Простий веб-додаток «Hello, World!» на Nginx, запакований у Docker-контейнер.
Його автоматично збирає, перевіряє та розгортає на тестовому сервері AWS EC2
pipeline на GitHub Actions після кожного коміту в `main`.

## Архітектура

```
 git push (main)
       │
       ▼
 ┌───────────────────────────── GitHub Actions ─────────────────────────────┐
 │ lint            build                                    deploy          │
 │ hadolint   ──►  docker build ─► smoke test ─► Trivy ─►   ssh + deploy.sh │
 │ shellcheck                                   push ──┐       │            │
 └─────────────────────────────────────────────────────┼───────┼────────────┘
                                                       ▼       ▼
                                               Docker Hub   EC2 (t3.micro, Amazon Linux 2023)
                                               :<sha>        └─ Docker: hello-nginx  :80 → :8080
                                               :latest          healthcheck + автоматичний rollback
```

| Компонент | Вибір | Чому |
|---|---|---|
| Веб-сервер | `nginx-unprivileged:stable-alpine` | малий образ, працює не від root |
| CI/CD | GitHub Actions | безкоштовний для публічних репозиторіїв |
| Registry | Docker Hub (публічний репозиторій) | безкоштовний, сервер робить `pull` без логіна |
| Сервер | AWS EC2 t3.micro, Amazon Linux 2023 | входить у Free plan |

### Структура репозиторію

```
├── app/index.html               # сторінка (версія підставляється під час збірки)
├── nginx/default.conf           # конфіг Nginx: /healthz, /nginx_status, security-заголовки
├── Dockerfile
├── .dockerignore                # у build context потрапляють лише app/ і nginx/
├── scripts/
│   ├── deploy.sh                # build / push / deploy / all
│   └── bootstrap-server.sh      # одноразове налаштування сервера (Docker, swap)
├── terraform/                   # інфраструктура AWS: SG, key pair, EC2, Elastic IP, (Budget)
└── .github/workflows/ci-cd.yml  # CI/CD pipeline
```

## Як працює pipeline

| Подія | lint | build + smoke test + scan | push у Docker Hub | deploy |
|---|:-:|:-:|:-:|:-:|
| Pull request у `main` | ✅ | ✅ | — | — |
| Push / merge у `main` | ✅ | ✅ | ✅ | ✅ |

1. **lint**: перевіряє Dockerfile через `hadolint`, а скрипти через `shellcheck`.
2. **build**:
   - `deploy.sh build` збирає образ із тегом `<git sha>` і `latest`;
   - smoke test запускає контейнер у режимі read-only і перевіряє `/healthz`, вміст сторінки та версію;
   - Trivy блокує pipeline, якщо в образі є HIGH/CRITICAL вразливості, для яких уже є виправлення;
   - `deploy.sh push` надсилає образ у Docker Hub.
3. **deploy**: `deploy.sh deploy` заходить на сервер по SSH і робить таке:
   - завантажує новий образ;
   - перейменовує поточний контейнер на `hello-nginx_prev`;
   - запускає новий контейнер і чекає статусу `healthy` від Docker HEALTHCHECK;
   - якщо статус `healthy`, видаляє старий контейнер;
   - якщо ні, **автоматично повертає попередню версію** і завершує pipeline з помилкою;
   - наприкінці перевіряє `http://<server>/healthz` ззовні.

Інші особливості:

- **Захист контейнера:** `--read-only`, `--cap-drop ALL`, `no-new-privileges`, ліміти пам'яті та процесів, ротація логів.
- **Послідовні деплої:** `concurrency` не дає двом деплоям іти одночасно.
- **Секрети:** зберігаються тільки в GitHub Secrets.
- **Простежуваність:** тег образу дорівнює git SHA, тому завжди відомо, який коміт зараз працює на сервері (`http://<server>/version.txt`).

## Налаштування з нуля

### Що потрібно
- Акаунти: GitHub, Docker Hub, AWS.
- Локально: `git`, `ssh`. Для локального запуску потрібен ще Docker.

### 1. Docker Hub
1. Створіть **публічний** репозиторій `hello-nginx`.
2. Відкрийте *Account settings → Personal access tokens → Generate new token* і створіть токен з правами **Read & Write**. Збережіть його, він знадобиться для GitHub.

### 2. Сервер в AWS (EC2)

> **Про бюджет.** Новий акаунт AWS (створений після 15.07.2025) отримує Free plan: кредити до $200 на 6 місяців. Коли кредити закінчуються, акаунт на Free plan закривається, а не виставляє рахунок. t3.micro коштує ≈ $7.5 на місяць, публічна IPv4-адреса ≈ $3.6 на місяць, і обидва платежі списуються з кредитів.

#### Варіант А: Terraform (рекомендовано)

Terraform створює все одразу: security group (порти 22 і 80), SSH-ключ, EC2 `t3.micro` на Amazon Linux 2023 і Elastic IP. Диск зашифрований, увімкнено лише IMDSv2. Docker і swap встановлюються автоматично через `user_data`: це той самий `scripts/bootstrap-server.sh`.

Що потрібно: Terraform ≥ 1.6 (версія закріплена в `terraform/.terraform-version` для tfenv) і вхід в AWS CLI (`aws login` або `aws configure`).

```bash
ssh-keygen -t ed25519 -N "" -C hello-nginx-deploy -f ~/.ssh/hello-nginx-deploy
```
```bash
cd terraform && terraform init && terraform apply
```
Після `apply` команда виведе `public_ip`, `app_url` і `ssh_command`. Bootstrap сервера займає ≈ 1–2 хвилини.

Далі покладіть у `known_hosts` справжній ключ сервера:
```bash
ssh-keyscan -t ed25519 <public_ip> > ~/.ssh/hello-nginx-known_hosts
```
Перш ніж довіряти цьому ключу, звірте його відбиток із консоллю інстансу: `ssh-keygen -lf ~/.ssh/hello-nginx-known_hosts` має показати той самий SHA256, що й `aws ec2 get-console-output --instance-id <id> --latest --output text | grep SHA256`.

Щоб видалити всю інфраструктуру, виконайте `terraform destroy`.

> Опційно: задайте `budget_alert_email` у `terraform/terraform.tfvars` (див. `terraform.tfvars.example`). Тоді Terraform створить AWS Budget зі сповіщенням на пошту, коли прогноз витрат перевищить 80% від ліміту.

#### Варіант Б: вручну через консоль AWS

1. Відкрийте *EC2 → Key pairs → Create key pair*. Тип **ED25519**, формат `.pem`. Збережіть файл, наприклад як `~/.ssh/hello-nginx.pem`, і виконайте `chmod 600 ~/.ssh/hello-nginx.pem`.
2. Відкрийте *EC2 → Launch instance* і задайте:
   - **AMI:** Amazon Linux 2023;
   - **Instance type:** `t3.micro`;
   - **Key pair:** ключ із кроку 1;
   - **Security group:** inbound-правила
     - `SSH 22` з `0.0.0.0/0`, бо GitHub Actions підключається з динамічних IP. Вхід можливий тільки по ключу, паролі на Amazon Linux вимкнені;
     - `HTTP 80` з `0.0.0.0/0`;
   - **Storage:** 8–30 GB gp3.
3. *(Рекомендовано)* Відкрийте *EC2 → Elastic IPs → Allocate* і прив'яжіть адресу до інстансу. Без цього IP зміниться після stop/start.
4. Підготуйте сервер. Docker встановлюється один раз:
   ```bash
   scp -i ~/.ssh/hello-nginx.pem scripts/bootstrap-server.sh ec2-user@<SERVER_IP>:
   ```
   ```bash
   ssh -i ~/.ssh/hello-nginx.pem ec2-user@<SERVER_IP> 'sudo bash bootstrap-server.sh'
   ```

### 3. GitHub-репозиторій
1. Створіть **публічний** репозиторій і запуште код:
   ```bash
   git init -b main
   git add .
   git commit -m "Initial commit"
   git remote add origin git@github.com:<you>/<repo>.git
   git push -u origin main
   ```
   Перший push запустить pipeline. Деплой на цьому кроці впаде, бо секрети ще не налаштовані. Це нормально: після кроку 2 перезапустіть workflow.
2. Відкрийте *Settings → Secrets and variables → Actions* і додайте значення:

   **Variables** (вкладка *Variables*):

   | Назва | Значення |
   |---|---|
   | `DOCKERHUB_USERNAME` | ваш логін Docker Hub |
   | `DEPLOY_HOST` | публічний IP або Elastic IP сервера |
   | `DEPLOY_USER` | *(необов'язково)* за замовчуванням `ec2-user` |

   **Secrets** (вкладка *Secrets*):

   | Назва | Значення |
   |---|---|
   | `DOCKERHUB_TOKEN` | токен із кроку 1 |
   | `SSH_PRIVATE_KEY` | приватний ключ: `~/.ssh/hello-nginx-deploy` (варіант А) або `~/.ssh/hello-nginx.pem` (варіант Б) |
   | `SSH_KNOWN_HOSTS` | вивід команди `ssh-keyscan -t ed25519 <SERVER_IP>` (захищає від MITM) |

   Те саме можна зробити з терміналу через `gh`:
   ```bash
   gh secret set SSH_PRIVATE_KEY < ~/.ssh/hello-nginx-deploy
   gh secret set SSH_KNOWN_HOSTS < ~/.ssh/hello-nginx-known_hosts
   gh secret set DOCKERHUB_TOKEN          # вставте токен у відповідь на запит
   gh variable set DOCKERHUB_USERNAME --body <dockerhub-user>
   gh variable set DEPLOY_HOST --body <public_ip>
   ```

3. Відкрийте *Actions → CI/CD → Run workflow* або зробіть будь-який коміт у `main`.

### 4. Перевірка
- Сайт: `http://<SERVER_IP>/`
- Health: `http://<SERVER_IP>/healthz` повертає `ok`.
- Версія: `http://<SERVER_IP>/version.txt` повертає SHA коміту, який зараз розгорнутий.
- Щоб перевірити автодеплой, змініть текст в `app/index.html`, закомітьте зміну в `main` і через ~1–2 хвилини оновіть сторінку.

## Локальний запуск і ручний деплой

Запуск лише на своїй машині:
```bash
docker build -t hello-nginx:local --build-arg APP_VERSION=local .
```
```bash
docker run --rm -p 8080:8080 hello-nginx:local
```
Сайт буде доступний на http://localhost:8080.

Ручний деплой тим самим скриптом, що й у CI:
```bash
docker login
```
```bash
export IMAGE_NAME=<dockerhub-user>/hello-nginx
export DEPLOY_HOST=<SERVER_IP>
export SSH_KEY=~/.ssh/hello-nginx.pem
./scripts/deploy.sh all          # build + push + deploy
```
Окремі кроки запускаються командами `./scripts/deploy.sh build`, `push` і `deploy`. Без аргументів скрипт виводить довідку.

### Корисні команди на сервері
```bash
docker ps                              # статус і health контейнера
docker logs -f hello-nginx             # access/error логи nginx
docker inspect --format '{{json .State.Health}}' hello-nginx
```

## Якщо щось не працює

| Симптом | Що перевірити |
|---|---|
| `deploy` падає з `Permission denied (publickey)` | `SSH_PRIVATE_KEY` вставлений повністю, разом із рядками `BEGIN`/`END`; `DEPLOY_USER` = `ec2-user` |
| `Host key verification failed` | `SSH_KNOWN_HOSTS` згенерований для поточного IP; після зміни IP згенеруйте його заново |
| `Service is not reachable from outside` | у security group відкритий порт 80 |
| Контейнер `unhealthy`, і стався rollback | лог у кроці *Deploy* (скрипт виводить `docker logs`) |
| `docker: permission denied` на сервері | після bootstrap перелогіньтесь, щоб застосувалась група `docker` |
| Trivy зупинив build | оновіть базовий образ (`--pull` вже увімкнений) або виправте знайдену вразливість |

## Подальші етапи (додаткові завдання)
- [x] **Terraform:** security group, EC2, Elastic IP, `bootstrap-server.sh` як `user_data`.
- [ ] **Kubernetes + ArgoCD (GitOps):** другий EC2 (`t3.small`) з k3s. CI оновлює тег образу в `k8s/`, а ArgoCD синхронізує кластер.
- [ ] **Моніторинг і логування:** Grafana Cloud Free + Grafana Alloy (метрики `stub_status`, логи контейнера).
