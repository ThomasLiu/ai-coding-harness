#!/bin/bash
# AI Coding Harness Repository Collector
# 收集 GitHub 上高星的 AI Coding Harness 仓库

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DATA_FILE="$SCRIPT_DIR/repos_data.json"
README_FILE="$SCRIPT_DIR/README.md"
ALL_REPOS_FILE="$SCRIPT_DIR/ALL_REPOS.md"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*"; }

KEYWORDS=("harness" "agentic" "claude-code" "coding-agent")

main() {
    log "开始采集..."
    
    TEMP_FILE=$(mktemp)
    
    first=true
    for keyword in "${KEYWORDS[@]}"; do
        log "搜索: $keyword"
        if result=$(gh search repos "$keyword" --sort stars --limit 100 --json name,owner,description,url,stargazersCount,createdAt 2>&1); then
            count=$(echo "$result" | jq length 2>/dev/null || echo "0")
            log "  -> $count 个仓库"
            if $first; then
                echo "$result" > "$TEMP_FILE"
                first=false
            else
                # 合并
                existing=$(cat "$TEMP_FILE")
                echo "$existing $result" | jq -s '.[0] + .[1]' > "$TEMP_FILE.tmp" 2>/dev/null || true
                if [[ -f "$TEMP_FILE.tmp" ]]; then
                    mv "$TEMP_FILE.tmp" "$TEMP_FILE"
                fi
            fi
        else
            error "搜索失败: $result"
        fi
        sleep 1
    done
    
    # 去重
    log "去重..."
    all_repos=$(cat "$TEMP_FILE" | jq 'unique_by(.url)' 2>/dev/null || echo "[]")
    count=$(echo "$all_repos" | jq length 2>/dev/null || echo "0")
    log "去重后: $count 个仓库"
    
    if [[ "$count" -eq 0 ]]; then
        error "没有收集到任何仓库"
        rm -f "$TEMP_FILE"
        return 1
    fi
    
    # 转换格式
    log "转换格式..."
    today=$(date '+%Y-%m-%d')
    echo "$all_repos" | jq --arg today "$today" '
        map({
            name: .name,
            owner: .owner.login,
            url: .url,
            description: (.description // ""),
            stars: (.stargazersCount // 0),
            created_at: .createdAt,
            last_updated: $today,
            history: [{date: $today, stars: (.stargazersCount // 0)}]
        })
    ' > "$TEMP_FILE.processed"
    
    # 更新数据文件
    log "更新数据文件..."
    echo "{\"version\": \"1.0.0\", \"last_collection\": \"$today\", \"repos\": " > "$DATA_FILE"
    cat "$TEMP_FILE.processed" >> "$DATA_FILE"
    echo "}" >> "$DATA_FILE"
    
    # 生成 README.md
    log "生成 README.md..."
    generate_readme
    
    # 生成 ALL_REPOS.md
    log "生成 ALL_REPOS.md..."
    generate_all_repos
    
    rm -f "$TEMP_FILE" "$TEMP_FILE.processed"
    
    log "完成! 共 $count 个仓库"
}

generate_readme() {
    today=$(date '+%Y-%m-%d')
    total=$(cat "$DATA_FILE" | jq '.repos | length')
    last=$(cat "$DATA_FILE" | jq -r '.last_collection' | cut -d'T' -f1)
    
    cat > "$README_FILE" << EOF
# AI Coding Harness Repos

> 自动采集 GitHub 上高星的 AI Coding Harness 仓库  
> 更新时间: $today | 最后采集: $last | 共 $total 个仓库

## 🔥 Top 10 总星榜

| # | 仓库 | 星数 | 简介 |
|---|------|------|------|
EOF

    cat "$DATA_FILE" | jq -r '.repos | sort_by(.stars) | reverse | .[0:10] | to_entries[] | 
        " | \((.key + 1)) | [\(.value.owner)/\(.value.name)](\(.value.url)) | \(.value.stars) | \(.value.description // "" | split(" ")[0:8] | join(" ")) |"' >> "$README_FILE"

    cat >> "$README_FILE" << 'EOF'

## 📈 Top 10 周增长榜

| # | 仓库 | 星数 | 周增长 | 简介 |
|---|------|------|--------|------|
EOF

    cat "$DATA_FILE" | jq -r '.repos | 
        map(select(.history | length >= 2)) |
        map({
            name, owner, url, stars, description,
            weekly_growth: (.history[0].stars - (.history[1].stars // .history[0].stars))
        }) |
        sort_by(.weekly_growth) | reverse | .[0:10] | to_entries[] | 
        " | \((.key + 1)) | [\(.value.owner)/\(.value.name)](\(.value.url)) | \(.value.stars) | +\(.value.weekly_growth) | \(.value.description // "" | split(" ")[0:8] | join(" ")) |"' >> "$README_FILE"

    cat >> "$README_FILE" << 'EOF'

## 数据说明

- 数据来源: GitHub Search API
- 搜索关键词: harness, agentic, claude-code, coding-agent
- 更新频率: 每 6 小时
- 周增长 = 当前星数 - 上次记录星数

## 相关仓库

- [ai-coding-fullstack](https://github.com/ThomasLiu/ai-coding-fullstack) - AI Coding 全自动开发方案
EOF
}

generate_all_repos() {
    today=$(date '+%Y-%m-%d')
    total=$(cat "$DATA_FILE" | jq '.repos | length')
    
    cat > "$ALL_REPOS_FILE" << "EOF"
# 全量仓库列表

> 所有收录的 AI Coding Harness 仓库

EOF

    cat "$DATA_FILE" | jq -r '.repos | sort_by(.stars) | reverse | .[] | @json' | while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        name=$(echo "$repo" | jq -r '.name')
        owner=$(echo "$repo" | jq -r '.owner')
        url=$(echo "$repo" | jq -r '.url')
        stars=$(echo "$repo" | jq -r '.stars')
        desc=$(echo "$repo" | jq -r '.description // ""')
        created=$(echo "$repo" | jq -r '.created_at // ""' | cut -d'T' -f1)

        cat >> "$ALL_REPOS_FILE" << EOF

### $owner/$name

- **星数**: $stars ⭐  
- **创建时间**: ${created:0:10}  
- **URL**: $url  
- **简介**: $desc
EOF
    done

    cat >> "$ALL_REPOS_FILE" << "EOF"

---
EOF
}

main "$@"
