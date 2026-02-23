#!/bin/bash
set -e

# Ollama CLI wrapper (following sage-review's pattern)
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
MODEL="${MODEL:-codellama:7b}"
OUTPUT_DIR=".ai-review/output"

usage() {
    echo "Usage: $0 <command> [options]"
    echo "Commands:"
    echo "  review --files <file1,file2> --model <model>"
    echo "  get-changed-files --pr <number> --repo <repo>"
    exit 1
}

get_changed_files() {
    local pr_number="$1"
    local repo="$2"
    
    echo "📁 Getting changed files for PR #$pr_number in repo $repo..."
    
    if [ -z "$GITHUB_TOKEN" ]; then
        echo "❌ GITHUB_TOKEN not set"
        exit 1
    fi
    
    mkdir -p "$OUTPUT_DIR"
    
    # Call GitHub API with error handling
    echo "🔍 Calling GitHub API..."
    local api_response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$repo/pulls/$pr_number/files")
    
    # Check if the response is an error
    if echo "$api_response" | jq -e '.message' >/dev/null 2>&1; then
        echo "❌ GitHub API Error:"
        echo "$api_response" | jq -r '.message'
        echo ""
        echo "💡 This might be because:"
        echo "   - The repository '$repo' doesn't exist"
        echo "   - PR #$pr_number doesn't exist"
        echo "   - Your token doesn't have access to this repo"
        echo "   - The token is invalid"
        exit 1
    fi
    
    # Save all files
    echo "$api_response" > "$OUTPUT_DIR/api-response.json"
    
    # Extract filenames
    echo "$api_response" | jq -r '.[].filename' > "$OUTPUT_DIR/all-files.txt"
    
    # Filter for code files
    grep -E '\.(py|js|ts|tsx|jsx|go|java|cpp|c|h|rs|php|rb|cs|html|css|json|yaml|yml|sh|bash)$' "$OUTPUT_DIR/all-files.txt" > "$OUTPUT_DIR/code-files.txt" || touch "$OUTPUT_DIR/code-files.txt"
    
    local file_count=$(wc -l < "$OUTPUT_DIR/code-files.txt" | tr -d ' ')
    echo "✅ Found $file_count code files"
    
    if [ "$file_count" -gt 0 ]; then
        echo "📄 Code files:"
        cat "$OUTPUT_DIR/code-files.txt" | sed 's/^/  - /'
    else
        echo "⚠️  No code files found in this PR"
    fi
}

call_ollama() {
    local model="$1"
    local prompt="$2"
    local system_prompt="$3"
    
    # Create request payload
    local payload=$(jq -n \
        --arg model "$model" \
        --arg prompt "$prompt" \
        --arg system "$system_prompt" \
        '{
            model: $model,
            prompt: ($system + "\n\n" + $prompt),
            stream: false,
            options: {
                temperature: 0.3,
                top_p: 0.9
            }
        }')
    
    # Call Ollama API
    curl -s -X POST "$OLLAMA_HOST/api/generate" \
        -H "Content-Type: application/json" \
        -d "$payload" | jq -r '.response'
}

review_files() {
    local files="$1"
    local model="$2"
    
    echo "🔍 Reviewing files with model: $model"
    
    mkdir -p "$OUTPUT_DIR"
    
    # Read files to review
    IFS=',' read -ra FILE_ARRAY <<< "$files"
    
    # System prompt (like sage-review's agent configs)
    local system_prompt="You are an expert code reviewer. Analyze code for:

🔒 SECURITY ISSUES:
- SQL injection, XSS, command injection
- Authentication/authorization flaws  
- Secrets in code, information disclosure
- Input validation issues

📐 CODE QUALITY:
- Complex functions, unclear naming
- Missing error handling
- Resource management issues
- Code readability problems

🏗️ DESIGN ISSUES:
- Architecture improvements needed
- Performance considerations
- API design issues

For each issue found, use this format:
**[CATEGORY_PRIORITY_##]** File: filename Line: X
**Issue**: Brief description
**Impact**: Why this matters
**Recommendation**: How to fix it

Categories: SECURITY, QUALITY, DESIGN
Priorities: CRITICAL, HIGH, MEDIUM, LOW"

    # Review each file
    echo "# AI Code Review Results" > "$OUTPUT_DIR/full-review.md"
    echo "" >> "$OUTPUT_DIR/full-review.md"
    
    for file in "${FILE_ARRAY[@]}"; do
        if [ -f "$file" ]; then
            echo "🔍 Reviewing $file..."
            
            # Read file content
            content=$(cat "$file")
            
            # Check for ignore markers
            if grep -q "AI-REVIEW-IGNORE-FILE\|REVIEW-IGNORE" "$file"; then
                echo "⏭️  Skipping $file (ignore marker found)"
                continue
            fi
            
            # Create prompt
            prompt="Please review this code file: $file

\`\`\`
$content
\`\`\`

Focus on genuine issues that need attention. Skip minor style issues."

            # Call Ollama
            echo "🤖 Analyzing with $model..."
            review_result=$(call_ollama "$model" "$prompt" "$system_prompt")
            
            # Save result
            echo "## $file" >> "$OUTPUT_DIR/full-review.md"
            echo "" >> "$OUTPUT_DIR/full-review.md"
            echo "$review_result" >> "$OUTPUT_DIR/full-review.md"
            echo "" >> "$OUTPUT_DIR/full-review.md"
            echo "---" >> "$OUTPUT_DIR/full-review.md"
            echo "" >> "$OUTPUT_DIR/full-review.md"
            
            echo "✅ Completed review of $file"
        else
            echo "⚠️  File not found: $file"
        fi
    done
    
    echo "✅ Review complete! Results saved to $OUTPUT_DIR/full-review.md"
}

# Main command handling
case "$1" in
    "get-changed-files")
        shift
        while [[ $# -gt 0 ]]; do
            case $1 in
                --pr) PR_NUMBER="$2"; shift 2 ;;
                --repo) REPO="$2"; shift 2 ;;
                *) echo "Unknown option: $1"; usage ;;
            esac
        done
        get_changed_files "$PR_NUMBER" "$REPO"
        ;;
    "review")
        shift
        while [[ $# -gt 0 ]]; do
            case $1 in
                --files) FILES="$2"; shift 2 ;;
                --model) MODEL="$2"; shift 2 ;;
                *) echo "Unknown option: $1"; usage ;;
            esac
        done
        review_files "$FILES" "$MODEL"
        ;;
    *) usage ;;
esac