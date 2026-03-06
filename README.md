# flux

**Natural language shell commands** — type plain English, get a shell command, run it instantly.

```
❯ fx list all txt files modified today
  ⠙ Thinking...
  ❯ find . -name "*.txt" -mtime -1

./notes.txt
./todo.txt
```

---

## Installation

```bash
# 1. Place the plugin folder
mkdir -p ~/.oh-my-zsh/custom/plugins/flux
# (copy flux.plugin.zsh here)

# 2. Add to your .zshrc
plugins=(... flux)

# 3. Reload shell
source ~/.zshrc

# 4. Run first-time setup
flux-setup
```

---

## Usage

Prefix any natural language instruction with `fx `:

```bash
fx show disk usage sorted by size
fx find all python files larger than 50kb
fx count lines in every txt file here
fx show the 5 biggest processes by memory
fx replace foo with bar in all .md files
```

The plugin will:
1. Show a spinner while calling the LLM
2. Display the generated command
3. Execute it immediately

> **No confirmation by default.** To enable: set `FLUX_CONFIRM="true"` in `~/.config/flux/config`.

---

## Setup & Configuration

### First-time setup

```bash
flux-setup
```

Interactive wizard — pick your provider, enter your API key (or complete OAuth for Copilot), and it tests the connection before saving.

### Switch between providers

```bash
flux-switch
```

Shows only the providers you've already configured:

```
=== flux Switch Model ===

Current: kimi-coding/kimi-for-coding

Configured providers:
  1) github-copilot/claude-sonnet-4.6
  2) kimi-coding/kimi-for-coding  ← current
  3) minimax-cn/abab6.5s-chat
  4) zai/glm-4-plus

Select [1-4] or q to quit:
```

Pick a number → connection is tested → model switches. No re-auth needed.

### Config file

`~/.config/flux/config`

```bash
FLUX_MODEL="github-copilot/claude-sonnet-4.6"   # provider/model
FLUX_CONFIRM="false"                              # ask before running?
```

### API keys storage

Each provider's key is stored separately:

```
~/.config/flux/keys/
  github-copilot      # OAuth token (auto-managed)
  kimi-coding         # sk-kimi-...
  zai                 # API key
  minimax-cn          # API key
  openai              # sk-...
  anthropic           # sk-ant-...
```

All key files are `chmod 600`.

---

## Supported Providers

| Provider | Model format | Auth |
|----------|-------------|------|
| **GitHub Copilot** | `github-copilot/<model>` | OAuth device flow (no API key needed) |
| **Kimi Coding** | `kimi-coding/kimi-for-coding` | API key from [kimi.moonshot.cn](https://kimi.moonshot.cn) |
| **ZAI (智谱AI)** | `zai/<model>` | API key from [open.bigmodel.cn](https://open.bigmodel.cn) |
| **Minimax** | `minimax-cn/<model>` | API key from [platform.minimax.io](https://platform.minimax.io) |
| **OpenAI** | `openai/<model>` | API key from [platform.openai.com](https://platform.openai.com) |
| **Anthropic** | `anthropic/<model>` | API key from [console.anthropic.com](https://console.anthropic.com) |
| **Groq** | `groq/<model>` | API key from [console.groq.com](https://console.groq.com) |
| **Mistral** | `mistral/<model>` | API key from [console.mistral.ai](https://console.mistral.ai) |
| **xAI (Grok)** | `xai/<model>` | API key from [console.x.ai](https://console.x.ai) |
| **OpenRouter** | `openrouter/<model>` | API key from [openrouter.ai](https://openrouter.ai) |
| **Google** | `google/<model>` | API key from [aistudio.google.com](https://aistudio.google.com) |

### GitHub Copilot (no API key needed)

During `flux-setup`, the plugin will:
1. Display a short code and a URL
2. Ask you to open the URL in a browser and enter the code
3. Wait for you to approve → done

Token is cached and auto-refreshed. Requires an active Copilot subscription.

### Kimi Coding (note)

The `kimi-coding` provider is for coding-agent keys (`sk-kimi-...`). These are **different** from Moonshot Open Platform keys. Get yours at [kimi.moonshot.cn](https://kimi.moonshot.cn).

---

## Requirements

- `zsh`
- `curl`
- `jq`
- `python3` (for Kimi Coding response parsing)

---

## Troubleshooting

**`FLUX_MODEL not set`**
→ Run `flux-setup`

**Plugin not loading**
→ Make sure `flux` is in `plugins=(...)` in `.zshrc` and you ran `source ~/.zshrc`

**Connection test failed on switch**
→ Check your API key: `cat ~/.config/flux/keys/<provider>`
→ Re-run `flux-setup` to re-enter the key for that provider

**Kimi connection test slow**
→ Normal — kimi-for-coding is a thinking model, takes a few seconds even for "say hi"

**GitHub Copilot token expired**
→ Automatic — the plugin refreshes it on every call. If it fails, delete `~/.config/flux/keys/github-copilot` and re-run `flux-setup`

---

## Uninstall

```bash
rm -rf ~/.oh-my-zsh/custom/plugins/flux
rm -rf ~/.config/flux
# Remove flux from plugins=(...) in ~/.zshrc
```

---

## License

MIT
