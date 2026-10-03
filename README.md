# Hey Inky

An AI-native handwritten notes app for iPad, for STEM students. Write with Apple Pencil, import
lecture slides, and summon **Inky** — an AI pen that answers by marking up your page.

## Quick start
```bash
# 1. Proxy (holds the OpenAI key; reads OpenAI_API_Key from ./.env)
cd proxy && npm install && npm start

# 2. App
brew install xcodegen
cd App && xcodegen generate && open HeyInky.xcodeproj   # run on an iPad simulator
```
Open "Welcome to Hey Inky", tap the Inky button (bottom right), and ask
"highlight the title of this page".

See [CLAUDE.md](CLAUDE.md) for architecture and CLI build/test, [DECISIONS.md](DECISIONS.md)
for the reasoning, and [PROGRESS.md](PROGRESS.md) for status.
