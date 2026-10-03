[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/we-promise/sure)
[![View performance data on Skylight](https://badges.skylight.io/typical/s6PEZSKwcklL.svg)](https://oss.skylight.io/app/applications/s6PEZSKwcklL)
[![Dosu](https://raw.githubusercontent.com/dosu-ai/assets/main/dosu-badge.svg)](https://app.dosu.dev/a72bdcfd-15f5-4edc-bd85-ea0daa6c3adc/ask)
[![Pipelock Security Scan](https://github.com/we-promise/sure/actions/workflows/pipelock.yml/badge.svg)](https://github.com/we-promise/sure/actions/workflows/pipelock.yml)

<img width="1270" height="1140" alt="sure_shot" src="https://github.com/user-attachments/assets/9c6e03cc-3490-40ab-9a68-52e042c51293" />

<p align="center">
  <a href="README.md">English</a> | 
  <a href="https://readme-i18n.com/de/we-promise/sure">Deutsch</a> | 
  <a href="https://readme-i18n.com/es/we-promise/sure">Español</a> | 
  <a href="https://readme-i18n.com/fr/we-promise/sure">Français</a> | 
  <a href="https://readme-i18n.com/ja/we-promise/sure">日本語</a> | 
  <a href="https://readme-i18n.com/ko/we-promise/sure">한국어</a> | 
  <a href="https://readme-i18n.com/pt/we-promise/sure">Português</a> | 
  <a href="https://readme-i18n.com/ru/we-promise/sure">Русский</a> | 
  <b>Українська</b> | 
  <a href="https://readme-i18n.com/zh/we-promise/sure">中文</a>
</p>

> [!NOTE]
> Це переклад [англійського README](README.md). Якщо версії відрізняються, актуальною вважається англійська.

# Sure: застосунок для особистих фінансів для всіх

<b>Долучайтеся: [Discord](https://discord.gg/36ZGBsxYEK) • [Вебсайт](https://sure.am) • [Issues](https://github.com/we-promise/sure/issues)</b>

> [!IMPORTANT]
> Цей репозиторій — це спільнотний форк проєкту Maybe Finance, розробку якого припинено. <br />
> Докладніше читайте в їхньому [фінальному релізі](https://github.com/maybe-finance/maybe/releases/tag/v0.6.0).

## Передісторія

Команда [Maybe Finance](https://github.com/maybe-finance/maybe) (репозиторій заархівовано й покинуто) провела більшу частину 2021–2022 років, створюючи повнофункціональний застосунок для керування особистими фінансами та капіталом. У ньому навіть була функція «Запитати радника», яка з'єднувала користувачів зі справжнім фінансовим консультантом (CFP/CFA), і все це входило у вартість підписки.

З бізнесового боку справи не склалися, тож у середині 2023 року розробку застосунку зупинили.

Витративши на розробку майже 1 мільйон доларів (працівники, підрядники, постачальники даних, інфраструктура тощо), команда відкрила вихідний код застосунку. Їхня мета була дати користувачам змогу безкоштовно розгортати його на власних серверах, а згодом запустити хостинг-версію за невелику плату.

І вони таки запустили цю хостинг-версію… ненадовго.

Це теж не спрацювало, принаймні як сталий B2C-бізнес. Тож ось ми тут: підтримуємо спільнотний форк, щоб зберегти кодову базу живою й подивитися, куди це може привести далі.

Приєднуйтеся до нас!

## Розгортання Sure

Sure — повністю робочий застосунок для особистих фінансів, який можна [розгорнути на власному сервері за допомогою Docker](docs/hosting/docker.md).

## Форки та зазначення авторства

Цей репозиторій — спільнотний форк заархівованого репозиторію Maybe Finance.
Ви можете вільно форкати його на умовах ліцензії AGPLv3, але ми будемо раді, якщо ви залишитеся й робитимете внесок тут.

Щоб дотримуватися вимог і уникнути проблем із торговельними марками:

- Обов'язково додайте оригінальну [ліцензію AGPLv3](https://github.com/maybe-finance/maybe/blob/main/LICENSE) і чітко вкажіть у своєму README, що ваш форк базується на Maybe Finance, але **не пов'язаний із Maybe Finance Inc. і не схвалений нею**.
- «Maybe» — торговельна марка Maybe Finance Inc., тому використовувати її (як і логотип) у форках НЕ дозволено.

## Проблеми з продуктивністю

У застосунках, що працюють з великими обсягами даних, проблеми з продуктивністю неминучі. Ми створили публічну панель, яка показує проблемні запити на демо-сайті разом зі стектрейсами, щоб їх було легше налагоджувати.

[https://www.skylight.io/app/applications/s6PEZSKwcklL/recent/6h/endpoints](https://oss.skylight.io/app/applications/s6PEZSKwcklL/recent/6h/endpoints)

Будь-які внески, що допомагають покращити продуктивність, дуже вітаються.

## Налаштування локальної розробки

**Якщо ви хочете _розгорнути застосунок на власному сервері_, [почніть із цього посібника](docs/hosting/docker.md).**

Інструкції нижче призначені для розробників, які хочуть долучитися до розробки застосунку.

### Вимоги

- Потрібну версію Ruby дивіться у файлі `.ruby-version`
- PostgreSQL >9.3 (рекомендовано останню стабільну версію)
- Redis > 5.4 (рекомендовано останню стабільну версію)

### Початок роботи
```sh
cd sure
cp .env.local.example .env.local
bin/setup
bin/dev

# За бажанням завантажте демо-дані
rake demo_data:default
```

Відкрийте http://localhost:3000, щоб побачити застосунок.

Якщо ви завантажили демо-дані, увійдіть з такими обліковими даними:

- Email: `user@example.com`
- Пароль: `Password1!`

Докладніші інструкції — у посібниках нижче.

### Посібники з налаштування

- [Налаштування для Mac](https://github.com/we-promise/sure/wiki/Mac-Dev-Setup-Guide) (англійською)
- [Налаштування для Linux](https://github.com/we-promise/sure/wiki/Linux-Dev-Setup-Guide) (англійською)
- [Налаштування для Windows](https://github.com/we-promise/sure/wiki/Windows-Dev-Setup-Guide) (англійською)
- Dev-контейнери — дивіться [цей посібник](https://code.visualstudio.com/docs/devcontainers/containers)

### Встановлення в один клік

[![Run on PikaPods](https://www.pikapods.com/static/run-button.svg)](https://www.pikapods.com/pods?run=sure)

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/sure?referralCode=CW_fPQ)

### Керований OpenClaw для Sure Finances

<a href="https://kilocode.pxf.io/repo-readme"><img src="https://kilo.ai/kiloclaw/partner-resources/kiloclaw-logo-yellow-bg-typography.png" alt="Managed OpenClaw for Sure Finances" width="185"/></a>


## Ліцензія та торговельні марки

Maybe і Sure поширюються на умовах
[ліцензії AGPLv3](https://github.com/we-promise/sure/blob/main/LICENSE).
- «Maybe» — торговельна марка Maybe Finance, Inc.
- «Sure» не є торговельною маркою і означає цей спільнотний форк.

![Alt](https://repobeats.axiom.co/api/embed/3a9753cff07501fba8a6749d0ebd567ff63848c8.svg "Repobeats analytics image")

<p align="center">
  <a href="https://gittensor.io/miners/repository?name=we-promise%2Fsure">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/we-promise/sure/gittensor-impact-assets/gittensor-impact-dark.svg">
      <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/we-promise/sure/gittensor-impact-assets/gittensor-impact-light.svg">
      <img src="https://raw.githubusercontent.com/we-promise/sure/gittensor-impact-assets/gittensor-impact-light.svg" alt="Gittensor contributor impact for Sure repo" width="600">
    </picture>
  </a>
</p>
