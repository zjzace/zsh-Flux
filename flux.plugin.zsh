# flux.plugin.zsh
# Natural Language Execute - oh-my-zsh plugin
# Intercepts commands prefixed with "fx " and generates shell commands via LLM

# =============================================================================
# Configuration
# =============================================================================

# Default values
: ${FLUX_MODEL:=github-copilot/gpt-4o}
: ${FLUX_CONFIRM:=false}

# Config file path
FLUX_CONFIG_FILE="${HOME}/.config/flux/config"

# Keys directory
FLUX_KEYS_DIR="${HOME}/.config/flux/keys"

# Copilot token cache file
FLUX_COPILOT_CACHE="${HOME}/.config/flux/.copilot_token_cache"

# =============================================================================
# Provider Registry - maps provider IDs to their API details
# =============================================================================

_flux_get_provider_config() {
    local provider="$1"
    case "$provider" in
        github-copilot)
            echo "base_url=https://api.github.com"
            echo "auth_type=copilot_oauth"
            ;;
        anthropic)
            echo "base_url=https://api.anthropic.com"
            echo "auth_type=api_key"
            ;;
        openai)
            echo "base_url=https://api.openai.com/v1"
            echo "auth_type=bearer"
            ;;
        zai)
            echo "base_url=https://open.bigmodel.cn/api/paas/v4"
            echo "auth_type=bearer"
            ;;
        minimax-cn)
            echo "base_url=https://api.minimax.chat/v1"
            echo "auth_type=bearer"
            ;;
        kimi-coding)
            echo "base_url=https://api.kimi.com/coding/v1"
            echo "auth_type=bearer"
            ;;
        google)
            echo "base_url=https://generativelanguage.googleapis.com/v1beta/openai"
            echo "auth_type=bearer"
            ;;
        mistral)
            echo "base_url=https://api.mistral.ai/v1"
            echo "auth_type=bearer"
            ;;
        groq)
            echo "base_url=https://api.groq.com/openai/v1"
            echo "auth_type=bearer"
            ;;
        xai)
            echo "base_url=https://api.x.ai/v1"
            echo "auth_type=bearer"
            ;;
        openrouter)
            echo "base_url=https://openrouter.ai/api/v1"
            echo "auth_type=bearer"
            ;;
        *)
            # Default: treat as OpenAI-compatible with bearer auth
            echo "base_url="
            echo "auth_type=bearer"
            ;;
    esac
}

# =============================================================================
# API Key Storage - separate file per provider
# =============================================================================

_flux_get_api_key() {
    local provider="$1"
    local keyfile="${FLUX_KEYS_DIR}/${provider}"
    [[ -f "$keyfile" ]] && cat "$keyfile"
}

_flux_set_api_key() {
    local provider="$1"
    local key="$2"
    mkdir -p "$FLUX_KEYS_DIR"
    echo "$key" > "${FLUX_KEYS_DIR}/${provider}"
    chmod 600 "${FLUX_KEYS_DIR}/${provider}"
}

# =============================================================================
# Config Loading
# =============================================================================

_flux_load_config() {
    if [[ -f "$FLUX_CONFIG_FILE" ]]; then
        source "$FLUX_CONFIG_FILE"
    fi
}

# Load config on plugin init
_flux_load_config

# =============================================================================
# Helper Functions
# =============================================================================

# Animated spinner while waiting for API
_flux_spinner() {
    local pid=$1
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  %s \e[36mThinking...\e[0m" "${frames[$((i % ${#frames[@]}))]}"
        i=$((i + 1))
        sleep 0.1
    done
    printf "\r\033[K"  # Clear spinner line
}

# Print command in a styled box
_flux_print_command() {
    local cmd="$1"
    local width=60
    local border=$(printf '─%.0s' $(seq 1 $((width - 4))))
    printf "\n  \e[90m╭─ Command %s╮\e[0m\n" "$border"
    printf "  \e[90m│\e[0m  \e[32;1m%s\e[0m\n" "$cmd"
    printf "  \e[90m╰%s╯\e[0m\n\n" "$(printf '─%.0s' $(seq 1 $((width - 2))))"
}

# Get shell context to send to LLM
_flux_get_context() {
    local context=""
    
    # Current working directory
    context+="Current directory: $(pwd)\n"
    
    # OS type
    context+="OS: $(uname -s)\n"
    
    # Last 5 commands from history
    context+="Recent history:\n"
    local history_count=0
    for ((i=${#history[@]}-1; i>=0 && history_count<5; i--)); do
        local cmd="${history[$i]}"
        # Skip empty lines and the current e command
        if [[ -n "$cmd" && "$cmd" != "fx "* && "$cmd" != "fx:"* ]]; then
            context+="  $cmd\n"
            ((history_count++))
        fi
    done
    
    echo "$context"
}

# Trim leading/trailing whitespace
_flux_trim() {
    local var="$1"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo "$var"
}

# =============================================================================
# OpenClaw Model Catalog Integration
# =============================================================================

# Fetch full model catalog from openclaw
_flux_fetch_catalog() {
    local all_models
    all_models=$(openclaw models list --all --plain 2>/dev/null)
    echo "$all_models"
}

# Extract unique providers from catalog
_flux_get_providers() {
    local catalog="$1"
    if [[ -z "$catalog" ]]; then
        return 1
    fi
    echo "$catalog" | cut -d'/' -f1 | sort -u
}

# Get models for a specific provider
_flux_get_models_for_provider() {
    local catalog="$1"
    local provider="$2"
    if [[ -z "$catalog" || -z "$provider" ]]; then
        return 1
    fi
    echo "$catalog" | grep "^${provider}/" | cut -d'/' -f2- | sort
}

# Count models for a provider
_flux_count_models_for_provider() {
    local catalog="$1"
    local provider="$2"
    _flux_get_models_for_provider "$catalog" "$provider" | wc -l
}

# =============================================================================
# GitHub Copilot Device Flow Helpers
# =============================================================================

# Get cached copilot token or refresh if needed
_flux_copilot_get_token() {
    local cached_token=""
    local expires_at=""
    
    # Check cache
    if [[ -f "$FLUX_COPILOT_CACHE" ]]; then
        cached_token=$(jq -r '.token' "$FLUX_COPILOT_CACHE" 2>/dev/null)
        expires_at=$(jq -r '.expires_at' "$FLUX_COPILOT_CACHE" 2>/dev/null)
        
        # Check if token is still valid (with 60 second buffer)
        if [[ -n "$expires_at" && "$expires_at" != "null" && "$expires_at" != "0" ]]; then
            local current_time
            current_time=$(date +%s)
            local expiry_time
            expiry_time=$expires_at
            
            if [[ $((expiry_time - current_time)) -gt 60 ]]; then
                echo "$cached_token"
                return 0
            fi
        fi
    fi
    
    # Need to refresh token
    _flux_copilot_refresh_token
}

# Get the per-user API endpoint from cache, or fallback to default
_flux_copilot_api_endpoint() {
    if [[ -f "$FLUX_COPILOT_CACHE" ]]; then
        local ep
        ep=$(jq -r '.api_endpoint // empty' "$FLUX_COPILOT_CACHE" 2>/dev/null)
        [[ -n "$ep" && "$ep" != "null" ]] && echo "$ep" && return
    fi
    echo "https://api.individual.githubcopilot.com"
}

# Refresh the copilot API token with explicit GitHub OAuth token (for setup phase)
_flux_copilot_refresh_token_with_key() {
    local github_token="$1"
    
    if [[ -z "$github_token" ]]; then
        echo "Error: GitHub OAuth token not provided" >&2
        return 1
    fi
    
    # Exchange GitHub OAuth token for Copilot API token - try v2 endpoint first
    local response
    response=$(curl -s https://api.github.com/copilot_internal/v2/token \
        -H "Authorization: token $github_token" \
        -H "Editor-Version: vscode/1.85.0" \
        -H "Editor-Plugin-Version: copilot-chat/0.12.0" \
        -H "User-Agent: GithubCopilot/1.155.0" 2>&1)
    
    if [[ "$response" == "curl: "* ]]; then
        echo "Error: $response" >&2
        return 1
    fi
    
    local token expires_at api_endpoint
    token=$(echo "$response" | jq -r '.token // empty' 2>/dev/null)
    expires_at=$(echo "$response" | jq -r '.expires_at // 0' 2>/dev/null)
    api_endpoint=$(echo "$response" | jq -r '.endpoints.api // "https://api.individual.githubcopilot.com"' 2>/dev/null)
    
    if [[ -z "$token" || "$token" == "null" ]]; then
        # Try alternative endpoint as fallback
        response=$(curl -s https://api.github.com/copilot_internal/token \
            -H "Authorization: token $github_token" \
            -H "Editor-Version: vscode/1.85.0" \
            -H "Editor-Plugin-Version: copilot-chat/0.12.0" \
            -H "User-Agent: GithubCopilot/1.155.0" 2>&1)
        
        token=$(echo "$response" | jq -r '.token // empty' 2>/dev/null)
        expires_at=$(echo "$response" | jq -r '.expires_at // 0' 2>/dev/null)
        api_endpoint=$(echo "$response" | jq -r '.endpoints.api // "https://api.individual.githubcopilot.com"' 2>/dev/null)
        
        if [[ -z "$token" || "$token" == "null" ]]; then
            echo "Error: Failed to get copilot token from either endpoint" >&2
            echo "Response: $response" >&2
            return 1
        fi
    fi
    
    # Cache: store token, expires_at, AND api_endpoint
    mkdir -p "$(dirname "$FLUX_COPILOT_CACHE")"
    jq -n --arg token "$token" --arg expires_at "$expires_at" --arg api_endpoint "$api_endpoint" \
        '{token: $token, expires_at: $expires_at, api_endpoint: $api_endpoint}' > "$FLUX_COPILOT_CACHE"
    
    echo "$token"
}

# Refresh the copilot API token
_flux_copilot_refresh_token() {
    # Get GitHub OAuth token from keys directory
    local github_token
    github_token=$(_flux_get_api_key "github-copilot")
    
    if [[ -z "$github_token" ]]; then
        echo "Error: No GitHub OAuth token found for 'github-copilot'. Run 'flux-setup' to configure." >&2
        return 1
    fi
    
    # Exchange GitHub OAuth token for Copilot API token - try v2 endpoint first
    local response
    response=$(curl -s https://api.github.com/copilot_internal/v2/token \
        -H "Authorization: token $github_token" \
        -H "Editor-Version: vscode/1.85.0" \
        -H "Editor-Plugin-Version: copilot-chat/0.12.0" \
        -H "User-Agent: GithubCopilot/1.155.0" 2>&1)
    
    if [[ "$response" == "curl: "* ]]; then
        echo "Error: $response" >&2
        return 1
    fi
    
    local token expires_at api_endpoint
    token=$(echo "$response" | jq -r '.token // empty' 2>/dev/null)
    expires_at=$(echo "$response" | jq -r '.expires_at // 0' 2>/dev/null)
    api_endpoint=$(echo "$response" | jq -r '.endpoints.api // "https://api.individual.githubcopilot.com"' 2>/dev/null)
    
    if [[ -z "$token" || "$token" == "null" ]]; then
        # Try alternative endpoint as fallback
        response=$(curl -s https://api.github.com/copilot_internal/token \
            -H "Authorization: token $github_token" \
            -H "Editor-Version: vscode/1.85.0" \
            -H "Editor-Plugin-Version: copilot-chat/0.12.0" \
            -H "User-Agent: GithubCopilot/1.155.0" 2>&1)
        
        token=$(echo "$response" | jq -r '.token // empty' 2>/dev/null)
        expires_at=$(echo "$response" | jq -r '.expires_at // 0' 2>/dev/null)
        api_endpoint=$(echo "$response" | jq -r '.endpoints.api // "https://api.individual.githubcopilot.com"' 2>/dev/null)
        
        if [[ -z "$token" || "$token" == "null" ]]; then
            local error_msg=$(echo "$response" | jq -r '.message // "Failed to get copilot token from both endpoints"' 2>/dev/null)
            echo "Error: $error_msg" >&2
            echo "Full response: $response" >&2
            return 1
        fi
    fi
    
    # Cache: store token, expires_at, AND api_endpoint
    mkdir -p "$(dirname "$FLUX_COPILOT_CACHE")"
    jq -n --arg token "$token" --arg expires_at "$expires_at" --arg api_endpoint "$api_endpoint" \
        '{token: $token, expires_at: $expires_at, api_endpoint: $api_endpoint}' > "$FLUX_COPILOT_CACHE"
    
    echo "$token"
}

# Full device flow setup (called during flux-setup)
_flux_copilot_device_flow() {
    local token_out="${1:-/tmp/flux-copilot-token.$$}"

    print -P "%F{cyan}=== GitHub Copilot Device Flow Authentication ===%f" >/dev/tty
    print "" >/dev/tty
    print "This will authenticate with GitHub to use Copilot." >/dev/tty
    print "You must have a GitHub Copilot subscription." >/dev/tty
    print "" >/dev/tty

    # Step 1: Get device code
    print -P "%F{yellow}Step 1: Requesting device code...%f" >/dev/tty
    local device_response
    device_response=$(curl -s -X POST https://github.com/login/device/code \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d '{"client_id":"Iv1.b507a08c87ecfe98","scope":"copilot"}' 2>&1)

    if [[ "$device_response" == "curl: "* ]]; then
        print "Error: $device_response" >/dev/tty
        return 1
    fi

    local device_code user_code verification_uri interval
    device_code=$(echo "$device_response" | jq -r '.device_code' 2>/dev/null)
    user_code=$(echo "$device_response" | jq -r '.user_code' 2>/dev/null)
    verification_uri=$(echo "$device_response" | jq -r '.verification_uri' 2>/dev/null)
    interval=$(echo "$device_response" | jq -r '.interval // 5' 2>/dev/null)

    if [[ -z "$device_code" || "$device_code" == "null" ]]; then
        print "Error: Failed to get device code. Response:" >/dev/tty
        print "$device_response" >/dev/tty
        return 1
    fi

    # Step 2: Show user code and instructions
    print "" >/dev/tty
    print -P "%F{yellow}%BStep 2: Authenticate%b%f" >/dev/tty
    print -P "  Visit:      %F{cyan}%B${verification_uri}%b%f" >/dev/tty
    print -P "  Enter code: %F{green}%B${user_code}%b%f" >/dev/tty
    print "" >/dev/tty
    print -P "%F{yellow}Waiting for authentication... (Press Ctrl+C to cancel)%f" >/dev/tty
    print "" >/dev/tty
    
    # Step 3: Poll for token
    local token_response poll_count=0
    while true; do
        sleep "$interval"
        ((poll_count++))
        
        token_response=$(curl -s -X POST https://github.com/login/oauth/access_token \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -d "{\"client_id\":\"Iv1.b507a08c87ecfe98\",\"device_code\":\"$device_code\",\"grant_type\":\"urn:ietf:params:oauth:grant-type:device_code\"}" 2>&1)
        
        if [[ "$token_response" == "curl: "* ]]; then
            print "Error: $token_response" >/dev/tty
            return 1
        fi

        local error_code
        error_code=$(echo "$token_response" | jq -r '.error // empty' 2>/dev/null)

        if [[ -n "$error_code" ]]; then
            if [[ "$error_code" == "authorization_pending" ]]; then continue; fi
            if [[ "$error_code" == "slow_down" ]]; then
                ((interval++))
                continue
            fi
            if [[ "$error_code" == "expired_token" ]]; then
                print "Error: Authentication timed out. Please try again." >/dev/tty
                return 1
            fi
            if [[ "$error_code" == "access_denied" ]]; then
                print "Error: Access denied. Please try again." >/dev/tty
                return 1
            fi
        fi

        local access_token
        access_token=$(echo "$token_response" | jq -r '.access_token' 2>/dev/null)

        if [[ -n "$access_token" && "$access_token" != "null" ]]; then
            break
        fi

        # Max 5 minutes
        if [[ $poll_count -gt 60 ]]; then
            print "Error: Authentication timed out. Please try again." >/dev/tty
            return 1
        fi

        print -n "." >/dev/tty
    done

    print "" >/dev/tty
    print -P "%F{green}✓ Authentication successful!%f" >/dev/tty
    print "" >/dev/tty

    # Write token to temp file
    echo "$access_token" > "$token_out"
}

# =============================================================================
# Test API Connection
# =============================================================================

_flux_test_connection() {
    local provider="$1"
    local base_url="$2"
    local api_key="$3"
    local model="$4"
    
    echo -n "Testing connection... "
    
    local response content
    
    # Build JSON body safely using jq
    local json_body
    json_body=$(jq -n \
        --arg model "$model" \
        --arg user "say hi" \
        '{
            model: $model,
            messages: [{role: "user", content: $user}],
            max_tokens: 5
        }')
    
    case "$provider" in
        anthropic)
            # Anthropic has different JSON structure
            response=$(curl -s -X POST "${base_url}/v1/messages" \
                -H "Content-Type: application/json" \
                -H "x-api-key: $api_key" \
                -H "anthropic-version: 2023-06-01" \
                -d "$json_body" \
                --max-time 15)
            content=$(echo "$response" | jq -r '.content[0].text // empty' 2>/dev/null)
            ;;
        github-copilot)
            local copilot_token
            copilot_token=$(_flux_copilot_get_token)
            if [[ -z "$copilot_token" ]]; then
                print -P "%F{red}✗ Failed to get Copilot token%f"
                return 1
            fi
            local api_ep
            api_ep=$(_flux_copilot_api_endpoint)
            response=$(curl -s -X POST "$api_ep/chat/completions" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $copilot_token" \
                -H "Editor-Version: vscode/1.85.0" \
                -H "Editor-Plugin-Version: copilot-chat/0.12.0" \
                -H "User-Agent: GithubCopilot/1.155.0" \
                -H "Copilot-Integration-Id: vscode-chat" \
                -d "$json_body" \
                --max-time 15)
            content=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
            ;;
        kimi-coding)
            # kimi-coding: thinking model — needs high token limit, Claude Code headers, and regex parse
            local kimi_body
            kimi_body=$(jq -n --arg model "$model" \
                '{model: $model, messages: [{role:"user",content:"say hi in one word"}], max_tokens: 2000, stream: false}')
            response=$(curl -s -X POST "${base_url}/chat/completions" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $api_key" \
                -H "User-Agent: claude-code/1.0" \
                -H "X-Stainless-Lang: js" \
                --max-time 30 \
                -d "$kimi_body")
            # Use regex to extract content (response has raw control chars from reasoning_content)
            content=$(echo "$response" | python3 -c "
import sys, re
raw = sys.stdin.buffer.read().decode('utf-8', errors='replace')
m = re.search(r'\"content\":\"(.*?)\"(?:,\"reasoning_content\"|\})', raw, re.DOTALL)
if m: print(m.group(1).strip())
" 2>/dev/null)
            ;;
        *)
            # OpenAI-compatible
            response=$(curl -s -X POST "${base_url}/chat/completions" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $api_key" \
                -d "$json_body" \
                --max-time 15)
            content=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
            ;;
    esac
    
    if [[ -n "$content" ]]; then
        print -P "%F{green}✓ Connection OK%f"
        return 0
    else
        local err=$(echo "$response" | jq -r '.error.message // .error // "unknown error"' 2>/dev/null)
        print -P "%F{red}✗ Connection failed: $err%f"
        return 1
    fi
}

# =============================================================================
# Call LLM API - derives everything from FLUX_MODEL
# =============================================================================

_flux_call_api() {
    local instruction="$1"
    local context="$2"
    
    # Parse provider/model from FLUX_MODEL
    local provider="${FLUX_MODEL%%/*}"
    local model="${FLUX_MODEL#*/}"
    
    # Get provider config
    local base_url auth_type
    eval "$(_flux_get_provider_config "$provider")"
    
    # Get API key
    local api_key
    api_key=$(cat "${HOME}/.config/flux/keys/${provider}" 2>/dev/null)
    
    if [[ -z "$api_key" ]]; then
        echo "Error: No API key found for provider '$provider'. Run 'flux-setup' to configure." >&2
        return 1
    fi
    
    # Build the prompt
    local system_prompt="You are a shell command generator. Given a natural language instruction and shell context, return ONLY the exact shell command to execute. Do NOT include any explanation, markdown fences, or additional text. Return ONLY the command."
    local user_prompt="Context:\n$context\n\nInstruction: $instruction\n\nGenerate the shell command:"
    
    # Determine endpoint based on provider
    local endpoint=""
    case "$provider" in
        openai)
            endpoint="${base_url}/chat/completions"
            ;;
        anthropic)
            endpoint="${base_url}/v1/messages"
            ;;
        github-copilot)
            endpoint="$(_flux_copilot_api_endpoint)/chat/completions"
            ;;
        zai)
            endpoint="${base_url}/chat/completions"
            ;;
        minimax-cn)
            endpoint="${base_url}/text/chatcompletion_v2"
            ;;
        kimi-coding)
            endpoint="${base_url}/chat/completions"
            # Add extra headers for kimi-coding
            json_body=$(jq -n \
                --arg model "$model" \
                --arg system "$system_prompt" \
                --arg user "$user_prompt" \
                '{
                    model: $model,
                    messages: [
                        {role: "system", content: $system},
                        {role: "user", content: $user}
                    ],
                    temperature: 0.3,
                    max_tokens: 4000,
                    stream: false
                }')
            
            response=$(curl -s -X POST "$endpoint" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $api_key" \
                -H "User-Agent: claude-code/1.0" \
                -H "X-Stainless-Lang: js" \
                --max-time 30 \
                -d "$json_body" 2>&1)
            ;;
        google)
            endpoint="${base_url}/models"
            ;;
        mistral)
            endpoint="${base_url}/chat/completions"
            ;;
        groq)
            endpoint="${base_url}/chat/completions"
            ;;
        xai)
            endpoint="${base_url}/chat/completions"
            ;;
        openrouter)
            endpoint="${base_url}/chat/completions"
            ;;
        *)
            endpoint="${base_url}/chat/completions"
            ;;
    esac
    
    # Build JSON body safely using jq
    local json_body response
    
    case "$provider" in
        anthropic)
            # Anthropic has different JSON structure (system param instead of messages)
            json_body=$(jq -n \
                --arg model "$model" \
                --arg system "$system_prompt" \
                --arg user "$user_prompt" \
                '{
                    model: $model,
                    system: $system,
                    messages: [{role: "user", content: $user}],
                    temperature: 0.3,
                    max_tokens: 500
                }')
            
            response=$(curl -s -X POST "$endpoint" \
                -H "Content-Type: application/json" \
                -H "x-api-key: $api_key" \
                -H "anthropic-version: 2023-06-01" \
                -d "$json_body" 2>&1)
            ;;
        github-copilot)
            # Get fresh copilot token
            local copilot_token
            copilot_token=$(_flux_copilot_get_token)
            if [[ -z "$copilot_token" ]]; then
                echo "Error: Failed to obtain Copilot token" >&2
                return 1
            fi
            
            json_body=$(jq -n \
                --arg model "$model" \
                --arg system "$system_prompt" \
                --arg user "$user_prompt" \
                '{
                    model: $model,
                    messages: [
                        {role: "system", content: $system},
                        {role: "user", content: $user}
                    ],
                    temperature: 0.3,
                    max_tokens: 500
                }')
            
            response=$(curl -s -X POST "$endpoint" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $copilot_token" \
                -H "Editor-Version: vscode/1.85.0" \
                -H "Editor-Plugin-Version: copilot-chat/0.12.0" \
                -H "User-Agent: GithubCopilot/1.155.0" \
                -H "Copilot-Integration-Id: vscode-chat" \
                -d "$json_body" 2>&1)
            ;;
        kimi-coding)
            # kimi-coding requires Claude Code agent headers and higher token limit (thinking model)
            json_body=$(jq -n \
                --arg model "$model" \
                --arg system "$system_prompt" \
                --arg user "$user_prompt" \
                '{
                    model: $model,
                    messages: [
                        {role: "system", content: $system},
                        {role: "user", content: $user}
                    ],
                    temperature: 0.3,
                    max_tokens: 4000,
                    stream: false
                }')
            response=$(curl -s -X POST "$endpoint" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $api_key" \
                -H "User-Agent: claude-code/1.0" \
                -H "X-Stainless-Lang: js" \
                --max-time 30 \
                -d "$json_body" 2>&1)
            ;;
        *)
            # OpenAI-compatible API (all others)
            json_body=$(jq -n \
                --arg model "$model" \
                --arg system "$system_prompt" \
                --arg user "$user_prompt" \
                '{
                    model: $model,
                    messages: [
                        {role: "system", content: $system},
                        {role: "user", content: $user}
                    ],
                    temperature: 0.3,
                    max_tokens: 500
                }')
            
            response=$(curl -s -X POST "$endpoint" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $api_key" \
                -d "$json_body" 2>&1)
            ;;
    esac
    
    # Check for curl errors
    if [[ "$response" == "curl: "* ]]; then
        echo "Error: $response" >&2
        return 1
    fi
    
    # Parse response based on provider
    local command=""
    case "$provider" in
        anthropic)
            command=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('content',[{}])[0].get('text',''))" 2>/dev/null)
            ;;
        kimi-coding)
            # kimi-coding returns reasoning_content with raw control chars — use regex extraction
            command=$(echo "$response" | python3 -c "
import sys, re
raw = sys.stdin.buffer.read().decode('utf-8', errors='replace')
m = re.search(r'\"content\":\"(.*?)\"(?:,\"reasoning_content\"|\})', raw, re.DOTALL)
if m:
    print(m.group(1).replace('\\\\n','').replace('\\\\t','').strip())
" 2>/dev/null)
            ;;
        *)
            command=$(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null)
            ;;
    esac
    
    # Check for API errors
    if [[ -z "$command" || "$command" == "null" ]]; then
        local error_msg=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); e=d.get('error',{}); print(e.get('message','Unknown error') if isinstance(e,dict) else str(e))" 2>/dev/null)
        echo "Error: $error_msg" >&2
        return 1
    fi
    
    # Clean up command - remove markdown fences and leading/trailing whitespace
    command=$(echo "$command" | sed -E '/^```/d' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    
    echo "$command"
}

# Execute the generated command
_flux_execute() {
    local command="$1"
    
    # Execute immediately - no confirmation prompt (unless FLUX_CONFIRM is true)
    if [[ "$FLUX_CONFIRM" == "true" ]]; then
        echo -n "Run? [Y/n] "
        local answer
        read -q answer
        echo
        if [[ "$answer" != "y" && "$answer" != "Y" && -n "$answer" ]]; then
            echo "Cancelled."
            return 1
        fi
    fi
    
    # Execute the command
    eval "$command"
}

# =============================================================================
# Main Handler - accept-line override
# =============================================================================

_flux_accept_line() {
    local line="$BUFFER"
    
    # Check if line starts with "e " (word boundary - e followed by space)
    if [[ "$line" =~ ^fx[[:space:]] ]]; then
        # Extract the instruction (everything after "fx ")
        local instruction="${line#fx }"
        instruction=$(_flux_trim "$instruction")
        
        if [[ -z "$instruction" ]]; then
            echo "Error: No instruction provided after 'e'" >&2
            zle reset-prompt
            return 1
        fi
        
        # Check for model configuration
        if [[ -z "$FLUX_MODEL" ]]; then
            echo "Error: FLUX_MODEL not set. Run 'flux-setup' to configure." >&2
            zle reset-prompt
            return 1
        fi
        
        # Get shell context
        local context=$(_flux_get_context)
        
        # Move to new line (avoid overlap with the input line)
        echo ""
        
        # Run API call in background, write result to temp file
        # Suppress zsh job control notifications ([1] 12345 / [1]+ done ...)
        setopt LOCAL_OPTIONS NO_MONITOR NO_NOTIFY
        local tmp_out=$(mktemp)
        local tmp_err=$(mktemp)
        (_flux_call_api "$instruction" "$context" > "$tmp_out" 2> "$tmp_err") &
        local api_pid=$!
        
        _flux_spinner $api_pid
        wait $api_pid
        local api_status=$?
        
        local generated_command=$(cat "$tmp_out")
        local api_error=$(cat "$tmp_err")
        rm -f "$tmp_out" "$tmp_err"
        
        if [[ $api_status -ne 0 || -n "$api_error" ]]; then
            printf "\n  \e[31m✗ Error:\e[0m %s\n\n" "$api_error"
            BUFFER=""
            zle reset-prompt
            return 1
        fi
        
        if [[ -z "$generated_command" ]]; then
            printf "\n  \e[31m✗ Error:\e[0m Empty response from API\n\n" >&2
            BUFFER=""
            zle reset-prompt
            return 1
        fi
        
        # Display command in styled box
        _flux_print_command "$generated_command"
        
        # Execute the command
        _flux_execute "$generated_command"
        local exec_status=$?
        
        # Show separator after output
        printf "\n  \e[90m─────────────────────────────────────────────\e[0m\n\n"
        
        # Clear the buffer after execution
        BUFFER=""
        zle reset-prompt
        
        return $exec_status
    fi
    
    # Not an e command, pass through to normal accept-line
    zle .accept-line
}

# Create the widget and bind to accept-line
zle -N accept-line _flux_accept_line

# =============================================================================
# Setup Command - uses OpenClaw model catalog
# =============================================================================

flux-setup() {
    print -P "%F{cyan}=== flux Setup ===%f" >/dev/tty
    print "" >/dev/tty
    print "This will configure ~/.config/flux/config" >/dev/tty
    print "" >/dev/tty
    
    # Step 1: Fetch catalog from openclaw
    local all_models
    all_models=$(openclaw models list --all --plain 2>/dev/null)
    
    if [[ -z "$all_models" ]]; then
        print -P "%F{yellow}Warning: could not fetch model catalog from openclaw. Falling back to manual entry.%f" >/dev/tty
    fi
    
    # Step 2: Show provider list
    local -a providers
    local -A provider_counts
    
    if [[ -n "$all_models" ]]; then
        providers=($(_flux_get_providers "$all_models"))
        for p in "${providers[@]}"; do
            local count=$(_flux_count_models_for_provider "$all_models" "$p")
            provider_counts[$p]=$count
        done
    else
        # Fallback providers
        providers=(github-copilot anthropic openai zai kimi-coding minimax-cn google mistral groq xai openrouter)
        for p in "${providers[@]}"; do
            provider_counts[$p]=0
        done
    fi
    
    print "Select a provider:" >/dev/tty
    print "" >/dev/tty
    
    local idx=1
    local -A provider_map
    for p in "${providers[@]}"; do
        local count="${provider_counts[$p]}"
        local count_str=""
        if [[ "$count" -gt 0 ]]; then
            count_str="($count models)"
        fi
        print "  $idx) $p $count_str" >/dev/tty
        provider_map[$idx]="$p"
        ((idx++))
    done
    
    print "" >/dev/tty
    print "  $idx) Enter manually" >/dev/tty
    local manual_option=$idx
    
    print "" >/dev/tty
    print -n "Select provider [1]: " >/dev/tty
    local provider_choice
    read provider_choice </dev/tty
    : ${provider_choice:=1}
    
    local selected_provider=""
    if [[ "$provider_choice" -ge 1 && "$provider_choice" -lt $manual_option ]]; then
        selected_provider="${provider_map[$provider_choice]}"
    elif [[ "$provider_choice" -eq $manual_option ]]; then
        print -n "Enter provider: " >/dev/tty
        read selected_provider </dev/tty
    else
        print "Invalid choice" >/dev/tty
        return 1
    fi
    
    # Step 3: Show model list for selected provider
    local -a models
    local selected_model=""
    
    if [[ -n "$all_models" && -n "$selected_provider" ]]; then
        models=($(_flux_get_models_for_provider "$all_models" "$selected_provider"))
    fi
    
    if [[ ${#models[@]} -gt 0 ]]; then
        print "" >/dev/tty
        print "Models for $selected_provider:" >/dev/tty
        print "" >/dev/tty
        
        idx=1
        for m in "${models[@]}"; do
            print "  $idx) $m" >/dev/tty
            ((idx++))
        done
        print "  $idx) Enter manually" >/dev/tty
        local model_manual=$idx
        
        print "" >/dev/tty
        print -n "Select [$manual_option]: " >/dev/tty
        local model_choice
        read model_choice </dev/tty
        : ${model_choice:=$manual_option}
        
        if [[ "$model_choice" -ge 1 && "$model_choice" -lt $model_manual ]]; then
            selected_model="${selected_provider}/${models[$((model_choice))]}"
        elif [[ "$model_choice" -eq $model_manual ]]; then
            print -n "Enter model name: " >/dev/tty
            local manual_model
            read manual_model </dev/tty
            selected_model="${selected_provider}/${manual_model}"
        else
            print "Invalid choice" >/dev/tty
            return 1
        fi
    else
        # No catalog or no models - use manual entry
        print -n "Enter model name for $selected_provider: " >/dev/tty
        local manual_model
        read manual_model </dev/tty
        selected_model="${selected_provider}/${manual_model}"
    fi
    
    # Step 4: API key
    local existing_key
    existing_key=$(_flux_get_api_key "$selected_provider")
    
    if [[ -n "$existing_key" ]]; then
        print "" >/dev/tty
        print -n "Use existing key for $selected_provider? [Y/n]: " >/dev/tty
        local use_existing
        read use_existing </dev/tty
        
        if [[ "$use_existing" == "n" || "$use_existing" == "N" ]]; then
            existing_key=""  # Force new key entry
        fi
    fi
    
    if [[ -z "$existing_key" ]]; then
        if [[ "$selected_provider" == "github-copilot" ]]; then
            # Run device flow auth
            local _copilot_token_tmp="/tmp/flux-copilot-token.$$"
            _flux_copilot_device_flow "$_copilot_token_tmp"
            if [[ $? -ne 0 || ! -f "$_copilot_token_tmp" ]]; then
                print "Failed to authenticate with GitHub Copilot." >/dev/tty
                rm -f "$_copilot_token_tmp"
                return 1
            fi
            local api_key
            api_key=$(cat "$_copilot_token_tmp")
            rm -f "$_copilot_token_tmp"
            
            if [[ -n "$api_key" ]]; then
                _flux_set_api_key "$selected_provider" "$api_key"
            fi
        else
            # Prompt for API key (masked)
            print -n "  API key: " >/dev/tty
            local -s api_key
            read api_key </dev/tty
            if [[ -n "$api_key" ]]; then
                _flux_set_api_key "$selected_provider" "$api_key"
            fi
        fi
    fi
    
    # Step 5: Test connection
    print "" >/dev/tty
    local provider_config base_url
    provider_config=$(_flux_get_provider_config "$selected_provider")
    base_url=$(echo "$provider_config" | grep "base_url=" | cut -d= -f2)
    
    local test_model="${selected_model#*/}"
    _flux_test_connection "$selected_provider" "$base_url" "$(_flux_get_api_key "$selected_provider")" "$test_model"
    
    # Step 6: Save config
    print "" >/dev/tty
    print -n "Enable confirmation before running commands? [y/N]: " >/dev/tty
    local confirm
    read confirm </dev/tty
    local confirm_setting="false"
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] && confirm_setting="true"
    
    # Create config directory
    mkdir -p "${HOME}/.config/flux"
    
    # Write config
    cat > "${HOME}/.config/flux/config" << EOF
# flux configuration
FLUX_MODEL="$selected_model"
FLUX_CONFIRM="$confirm_setting"
EOF
    
    print "" >/dev/tty
    print -P "%F{green}✓ Configuration saved to ~/.config/flux/config%f" >/dev/tty
    print "" >/dev/tty
    print "Model: $selected_model" >/dev/tty
    print "API key: stored in ~/.config/flux/keys/$selected_provider" >/dev/tty
    print "" >/dev/tty
    print "Restart your shell or source the plugin to use flux!" >/dev/tty
    print "" >/dev/tty
    print "Usage: e <instruction>" >/dev/tty
    print "Example: e show the first 2 lines of foo.txt" >/dev/tty
}

# =============================================================================
# Quick Switch Command
# =============================================================================

flux-switch() {
    # Default models per provider (fallback when no current model for that provider)
    local -A _default_models
    _default_models=(
        [github-copilot]="github-copilot/claude-sonnet-4.6"
        [kimi-coding]="kimi-coding/kimi-for-coding"
        [kimi]="kimi-coding/kimi-for-coding"
        [zai]="zai/glm-4-plus"
        [minimax-cn]="minimax-cn/abab6.5s-chat"
        [anthropic]="anthropic/claude-opus-4-5"
        [openai]="openai/gpt-4o"
        [groq]="groq/llama-3.3-70b-versatile"
        [mistral]="mistral/mistral-large-latest"
        [xai]="xai/grok-2"
        [openrouter]="openrouter/anthropic/claude-3.5-sonnet"
        [google]="google/gemini-2.0-flash"
    )

    print -P "%F{cyan}=== flux Switch Model ===%f" >/dev/tty
    print "" >/dev/tty
    print "Current: %F{yellow}${FLUX_MODEL}%f" >/dev/tty
    print "" >/dev/tty

    # Discover configured providers from keys directory
    local keys_dir="${HOME}/.config/flux/keys"
    if [[ ! -d "$keys_dir" ]]; then
        print -P "%F{red}No keys configured. Run 'flux-setup' first.%f" >/dev/tty
        return 1
    fi

    local -a configured_providers
    configured_providers=($(ls "$keys_dir" 2>/dev/null))

    if [[ ${#configured_providers[@]} -eq 0 ]]; then
        print -P "%F{red}No keys found in $keys_dir. Run 'flux-setup' first.%f" >/dev/tty
        return 1
    fi

    # Build list of provider/model entries
    local current_provider="${FLUX_MODEL%%/*}"
    local -a entries
    for p in "${configured_providers[@]}"; do
        if [[ "$p" == "$current_provider" ]]; then
            # Use the current configured model for this provider
            entries+=("${FLUX_MODEL}")
        else
            # Use default model for this provider
            local def="${_default_models[$p]}"
            if [[ -n "$def" ]]; then
                entries+=("$def")
            else
                entries+=("${p}/default")
            fi
        fi
    done

    # Display numbered list
    print "Configured providers:" >/dev/tty
    print "" >/dev/tty
    local idx=1
    for entry in "${entries[@]}"; do
        if [[ "$entry" == "$FLUX_MODEL" ]]; then
            print -P "  %F{green}$idx) $entry  ← current%f" >/dev/tty
        else
            print "  $idx) $entry" >/dev/tty
        fi
        ((idx++))
    done

    print "" >/dev/tty
    print -n "Select [1-${#entries[@]}] or q to quit: " >/dev/tty
    local choice
    read choice </dev/tty

    [[ "$choice" == "q" || "$choice" == "Q" || -z "$choice" ]] && return 0

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt ${#entries[@]} ]]; then
        print -P "%F{red}Invalid selection.%f" >/dev/tty
        return 1
    fi

    local selected_model="${entries[$choice]}"
    local selected_provider="${selected_model%%/*}"
    local selected_modelname="${selected_model#*/}"

    if [[ "$selected_model" == "$FLUX_MODEL" ]]; then
        print -P "\n%F{yellow}Already using $selected_model%f" >/dev/tty
        return 0
    fi

    # Test the connection before switching
    print "" >/dev/tty
    print -n "Testing connection to $selected_model... " >/dev/tty

    local api_key
    api_key=$(cat "${HOME}/.config/flux/keys/${selected_provider}" 2>/dev/null)

    local base_url auth_type
    eval "$(_flux_get_provider_config "$selected_provider")"

    local test_result
    test_result=$(_flux_test_connection "$selected_provider" "$base_url" "$api_key" "$selected_modelname" 2>&1)
    local test_status=$?

    if [[ $test_status -eq 0 ]]; then
        print -P "%F{green}✓ OK%f" >/dev/tty
    else
        print -P "%F{red}✗ Failed%f" >/dev/tty
        print -P "%F{red}Error: $test_result%f" >/dev/tty
        print -P "%F{yellow}Not switching — connection test failed.%f" >/dev/tty
        return 1
    fi

    # Write config
    local confirm_setting="false"
    if [[ -f "${HOME}/.config/flux/config" ]]; then
        confirm_setting=$(grep "^FLUX_CONFIRM=" "${HOME}/.config/flux/config" 2>/dev/null | cut -d'"' -f2)
        [[ -z "$confirm_setting" ]] && confirm_setting="false"
    fi

    cat > "${HOME}/.config/flux/config" << EOF
# flux configuration
FLUX_MODEL="$selected_model"
FLUX_CONFIRM="$confirm_setting"
EOF

    # Reload in current shell
    FLUX_MODEL="$selected_model"

    print -P "\n%F{green}✓ Switched to: $selected_model%f" >/dev/tty
}

# =============================================================================
# Init - show hint if not configured
# =============================================================================

_flux_init() {
    if [[ ! -f "$FLUX_CONFIG_FILE" ]]; then
        print -P "%F{yellow}flux: Run 'flux-setup' to configure your model.%f"
    fi
}

# Run init on plugin load
_flux_init
