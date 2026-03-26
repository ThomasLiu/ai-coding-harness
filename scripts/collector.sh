#!/bin/bash
# AI Coding Harness Repository Collector
# 收集 GitHub 上高星的 AI Coding Harness 仓库

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DATA_FILE="$SCRIPT_DIR/repos_data.json"
README_FILE="$SCRIPT_DIR/README.md"
ALL_REPOS_FILE="$SCRIPT_DIR/ALL_REPOS.md"

# AI 分析阈值：只分析 Stars >= 30000 的仓库
AI_ANALYSIS_THRESHOLD=30000

log() { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*"; }

KEYWORDS=("harness" "agentic" "claude-code" "coding-agent")

# AI 分析提示词
AI_PROMPT=$'分析这个 GitHub 仓库，输出格式：\n[CN_DESC]中文简介（50字内）[/CN_DESC]\n[PROS]优点1|优点2|优点3[/PROS]\n[CONS]缺点1|缺点2[/CONS]'

main() {
    log "开始采集..."

    TEMP_FILE=$(mktemp)

    first=true
    for keyword in "${KEYWORDS[@]}"; do
        log "搜索: $keyword"
        if result=$(gh search repos "$keyword" --sort stars --limit 100 --json name,owner,description,url,stargazersCount,createdAt,updatedAt 2>&1); then
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

    # 转换格式，保留已有分析数据
    log "转换格式..."
    today=$(date '+%Y-%m-%d')

    # 读取已有分析数据，构建 URL -> 分析数据 映射
    existing_analysis=$(cat "$DATA_FILE" 2>/dev/null | jq 'INDEX(.repos[].url) | to_entries[] | {url: .key, description_zh: .value.description_zh, pros: .value.pros, cons: .value.cons, analyzed: .value.analyzed}' 2>/dev/null || echo "[]")

    echo "$all_repos" | jq --arg today "$today" --argjson existing "$existing_analysis" '
        def getExisting(url):
            $existing | map(select(.url == url)) | first // {};
        map({
            name: .name,
            owner: .owner.login,
            url: .url,
            description: (.description // ""),
            description_zh: (getExisting(.url).description_zh // ""),
            pros: (getExisting(.url).pros // []),
            cons: (getExisting(.url).cons // []),
            analyzed: (getExisting(.url).analyzed // false),
            stars: (.stargazersCount // 0),
            created_at: .createdAt,
            repo_updated_at: .updatedAt,
            last_collected_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
            last_updated: $today,
            history: [{date: $today, stars: (.stargazersCount // 0)}]
        })
    ' > "$TEMP_FILE.processed"

    # 更新数据文件
    log "更新数据文件..."
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "{\"version\": \"1.0.0\", \"collected_at\": \"$now_iso\", \"last_collection\": \"$today\", \"repos\": " > "$DATA_FILE"
    cat "$TEMP_FILE.processed" >> "$DATA_FILE"
    echo "}" >> "$DATA_FILE"

    # AI 分析高星仓库
    log "AI 分析高星仓库 (Stars >= $AI_ANALYSIS_THRESHOLD)..."
    analyze_high_stars_repos

    # 生成 README.md
    log "生成 README.md..."
    generate_readme

    # 生成 ALL_REPOS.md
    log "生成 ALL_REPOS.md..."
    generate_all_repos

    rm -f "$TEMP_FILE" "$TEMP_FILE.processed"

    log "完成! 共 $count 个仓库"
}

# AI 分析 Stars >= 30000 的仓库
analyze_high_stars_repos() {
    local repos_to_analyze=$(cat "$DATA_FILE" | jq --arg threshold "$AI_ANALYSIS_THRESHOLD" \
        '.repos | to_entries[] | select(.value.stars >= ($threshold | tonumber) and .value.analyzed != true) | .key')

    local total_to_analyze=$(echo "$repos_to_analyze" | grep -c '^' || echo "0")

    if [[ "$total_to_analyze" -eq 0 ]]; then
        log "没有需要分析的仓库（均已分析或星数不足）"
        return
    fi

    log "需要分析 $total_to_analyze 个仓库"

    for idx in $repos_to_analyze; do
        local repo_json=$(cat "$DATA_FILE" | jq ".repos[$idx]")
        local name=$(echo "$repo_json" | jq -r '.name')
        local url=$(echo "$repo_json" | jq -r '.url')
        local stars=$(echo "$repo_json" | jq -r '.stars')

        log "分析 [$idx] $name (Stars: $stars)..."

        # 调用 Claude Code 分析
        local full_prompt="${AI_PROMPT}"$'\n\n'"请分析此仓库: $url"
        if analysis=$(claude -p "$full_prompt" 2>&1); then
            # 解析分析结果
            local cn_desc=$(echo "$analysis" | grep -oE '\[CN_DESC\].*?\[/CN_DESC\]' | sed 's/\[CN_DESC\]//;s/\[\/CN_DESC\]//')
            local pros_line=$(echo "$analysis" | grep -oE '\[PROS\].*?\[/PROS\]' | sed 's/\[PROS\]//;s/\[\/PROS\]//')
            local cons_line=$(echo "$analysis" | grep -oE '\[CONS\].*?\[/CONS\]' | sed 's/\[CONS\]//;s/\[\/CONS\]//')

            # 转换 pros 和 cons 为 JSON 数组
            local pros_json="[]"
            local cons_json="[]"

            if [[ -n "$pros_line" ]]; then
                pros_json=$(echo "$pros_line" | jq -R 'split("|")' 2>/dev/null || echo "[]")
            fi
            if [[ -n "$cons_line" ]]; then
                cons_json=$(echo "$cons_line" | jq -R 'split("|")' 2>/dev/null || echo "[]")
            fi

            # 更新 JSON 数据
            cat "$DATA_FILE" | jq --arg idx "$idx" --arg cn_desc "$cn_desc" --argjson pros "$pros_json" --argjson cons "$cons_json" \
                '.repos[$idx | tonumber].description_zh = $cn_desc | .repos[$idx | tonumber].pros = $pros | .repos[$idx | tonumber].cons = $cons | .repos[$idx | tonumber].analyzed = true' \
                > "$DATA_FILE.tmp" && mv "$DATA_FILE.tmp" "$DATA_FILE"

            log "  -> 分析完成: $cn_desc"
        else
            error "  -> 分析失败: $analysis"
        fi

        # 间隔 2 秒避免 API 限流
        sleep 2
    done
}

generate_readme() {
    today=$(date '+%Y-%m-%d')
    total=$(cat "$DATA_FILE" | jq '.repos | length')
    analyzed_count=$(cat "$DATA_FILE" | jq '[.repos[] | select(.analyzed == true)] | length')
    collected_at=$(cat "$DATA_FILE" | jq -r '.collected_at // empty')
    last=$(cat "$DATA_FILE" | jq -r '.last_collection' | cut -d'T' -f1)

    cat > "$README_FILE" << EOF
# AI Coding Harness Repos

> 自动采集 GitHub 上高星的 AI Coding Harness 仓库
> 更新时间: $today | 最后采集: $last | 数据采集时间: $collected_at | 共 $total 个仓库 | 已 AI 分析: $analyzed_count 个

## 🔥 Top 10 总星榜

| # | 仓库 | 星数 | 简介 |
|---|------|------|------|
EOF

    cat "$DATA_FILE" | jq -r '.repos | sort_by(.stars) | reverse | .[0:10] | to_entries[] |
        (if .value.analyzed then
            " | \((.key + 1)) | [\(.value.owner)/\(.value.name)](\(.value.url)) | \(.value.stars) | \(.value.description_zh // .value.description) |"
        else
            " | \((.key + 1)) | [\(.value.owner)/\(.value.name)](\(.value.url)) | \(.value.stars) | \(.value.description // "" | split(" ")[0:8] | join(" ")) ⭐待AI分析 |"
        end)' >> "$README_FILE"

    cat >> "$README_FILE" << 'EOF'

## 📈 Top 10 周增长榜

| # | 仓库 | 星数 | 周增长 | 简介 |
|---|------|------|--------|------|
EOF

    cat "$DATA_FILE" | jq -r '.repos |
        map(select(.history | length >= 2)) |
        map({
            name, owner, url, stars, description, description_zh, analyzed,
            weekly_growth: (.history[0].stars - (.history[1].stars // .history[0].stars))
        }) |
        sort_by(.weekly_growth) | reverse | .[0:10] | to_entries[] |
        (if .value.analyzed then
            " | \((.key + 1)) | [\(.value.owner)/\(.value.name)](\(.value.url)) | \(.value.stars) | +\(.value.weekly_growth) | \(.value.description_zh // .value.description) |"
        else
            " | \((.key + 1)) | [\(.value.owner)/\(.value.name)](\(.value.url)) | \(.value.stars) | +\(.value.weekly_growth) | \(.value.description // "" | split(" ")[0:8] | join(" ")) ⭐待AI分析 |"
        end)' >> "$README_FILE"

    cat >> "$README_FILE" << 'EOF'

## 数据说明

- 数据来源: GitHub Search API
- 搜索关键词: harness, agentic, claude-code, coding-agent
- 更新频率: 每 6 小时
- 周增长 = 当前星数 - 上次记录星数
- AI 分析阈值: Stars >= 30000，仅分析高星仓库以控制 API 成本

## 相关仓库

- [ai-coding-fullstack](https://github.com/ThomasLiu/ai-coding-fullstack) - AI Coding 全自动开发方案
EOF
}

generate_all_repos() {
    today=$(date '+%Y-%m-%d')
    total=$(cat "$DATA_FILE" | jq '.repos | length')
    analyzed_count=$(cat "$DATA_FILE" | jq '[.repos[] | select(.analyzed == true)] | length')

    cat > "$ALL_REPOS_FILE" << EOF
# 全量仓库列表

> 所有收录的 AI Coding Harness 仓库 | 共 $total 个 | 已 AI 分析: $analyzed_count 个

EOF

    cat "$DATA_FILE" | jq -r '.repos | sort_by(.stars) | reverse | to_entries[] | @json' | while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        idx=$(echo "$entry" | jq -r '.key')
        repo=$(echo "$entry" | jq -r '.value')
        name=$(echo "$repo" | jq -r '.name')
        owner=$(echo "$repo" | jq -r '.owner')
        url=$(echo "$repo" | jq -r '.url')
        stars=$(echo "$repo" | jq -r '.stars')
        desc=$(echo "$repo" | jq -r '.description // ""')
        desc_zh=$(echo "$repo" | jq -r '.description_zh // ""')
        pros=$(echo "$repo" | jq -r '.pros // []')
        cons=$(echo "$repo" | jq -r '.cons // []')
        analyzed=$(echo "$repo" | jq -r '.analyzed // false')
        created=$(echo "$repo" | jq -r '.created_at // ""' | cut -d'T' -f1)

        if $analyzed && [[ -n "$desc_zh" ]]; then
            # 已分析的仓库显示中文简介和优缺点
            pros_items=$(echo "$pros" | jq -r '.[]' 2>/dev/null | sed 's/^/- /' | tr '\n' ' ')
            cons_items=$(echo "$cons" | jq -r '.[]' 2>/dev/null | sed 's/^/- /' | tr '\n' ' ')

            cat >> "$ALL_REPOS_FILE" << EOF

### $owner/$name

- **星数**: $stars ⭐
- **创建时间**: ${created:0:10}
- **URL**: $url
- **简介**: $desc_zh
- **优点**: $pros_items
- **缺点**: $cons_items
EOF
        else
            # 未分析的仓库显示原始描述
            cat >> "$ALL_REPOS_FILE" << EOF

### $owner/$name

- **星数**: $stars ⭐ ⭐待AI分析
- **创建时间**: ${created:0:10}
- **URL**: $url
- **简介**: $desc
EOF
        fi
    done

    cat >> "$ALL_REPOS_FILE" << "EOF"

---
EOF
}

main "$@"
