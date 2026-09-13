#!/bin/bash

set -u
set -o pipefail

usage() {
    echo "Usage: $(basename "$0") [4|6]"
    echo "  4  Force IPv4 detection"
    echo "  6  Force IPv6 detection"
    echo "  no arg = test both IPv4 and IPv6"
    exit 0
}

UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36'

# 全局 GeoIP（仅用于 GeoIP 列，不影响服务地区判断）
DETECTED_REGION=""

# ── GeoIP 检测（OneTrust → ip-api.com）──
detect_region() {
    local ip_flag="$1"
    local region=""

    local onetrust=$(curl "$ip_flag" -s --max-time 5 \
        'https://geolocation.onetrust.com/cookieconsentpub/v1/geo/location' \
        --user-agent "$UA" 2>/dev/null || true)
    if [ -n "$onetrust" ]; then
        region=$(echo "$onetrust" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
    fi

    if [ -z "$region" ]; then
        local ipapi=$(curl "$ip_flag" -s --max-time 5 \
            'http://ip-api.com/json/' 2>/dev/null || true)
        if [ -n "$ipapi" ]; then
            region=$(echo "$ipapi" | grep -o '"countryCode":"[^"]*"' | cut -d'"' -f4)
        fi
    fi

    DETECTED_REGION="$region"
}

# ── 国家名 → 2字母代码 ──
# Google Play Store 返回全名，统一转代码
country_code() {
    case "$1" in
        *"United States"*)     echo "US" ;;
        *"Hong Kong"*)         echo "HK" ;;
        *"Macao"*)             echo "MO" ;;
        *"Taiwan"*)            echo "TW" ;;
        *"Singapore"*)         echo "SG" ;;
        *"Japan"*)             echo "JP" ;;
        *"South Korea"*)       echo "KR" ;;
        *"United Kingdom"*)    echo "GB" ;;
        *"Canada"*)            echo "CA" ;;
        *"Australia"*)         echo "AU" ;;
        *"Germany"*)           echo "DE" ;;
        *"France"*)            echo "FR" ;;
        *"India"*)             echo "IN" ;;
        *"Malaysia"*)          echo "MY" ;;
        *"Indonesia"*)         echo "ID" ;;
        *"Thailand"*)          echo "TH" ;;
        *"Vietnam"*)           echo "VN" ;;
        *"Philippines"*)       echo "PH" ;;
        *"Brazil"*)            echo "BR" ;;
        *"Mexico"*)            echo "MX" ;;
        *"Russia"*)            echo "RU" ;;
        *"Netherlands"*)       echo "NL" ;;
        *)                     echo "$1" ;;
    esac
}

# ── 输出（5列：网络/服务/状态/服务报告地区/GeoIP）──
print_result() {
    local label="$1"
    local service="$2"
    local status="$3"
    local svc_region="$4"    # 服务自己报告的地区
    local geoip="$5"         # OneTrust/ip-api 定位
    printf "%-6s | %-16s | %-15s | %-6s | %s\n" \
        "$label" "$service" "$status" "${svc_region:--}" "${geoip:--}"
}

# ── Google ──
# 地区来源优先级: google.cn 跳转 → Play Store 国家 → 无
check_google() {
    local ip_flag="$1"
    local label="$2"

    local result=$(curl "$ip_flag" -sL --max-time 10 \
        -H 'accept-language: en-US,en;q=0.9' \
        -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8' \
        -H 'sec-fetch-dest: document' -H 'sec-fetch-mode: navigate' -H 'sec-fetch-site: none' \
        --user-agent "$UA" \
        'https://www.google.com/' 2>/dev/null || true)

    if [ -z "$result" ]; then
        print_result "$label" "Google" "FAIL" "" "$DETECTED_REGION"
        return
    fi

    # CN: 跳转 google.cn
    if echo "$result" | grep -q 'www\.google\.cn'; then
        print_result "$label" "Google" "OK" "CN" "$DETECTED_REGION"
        return
    fi

    # CAPTCHA
    if echo "$result" | grep -qiE 'unusual traffic from|is blocked|unaddressed abuse'; then
        print_result "$label" "Google" "BLOCKED" "" "$DETECTED_REGION"
        return
    fi

    # 通过 Google Play Store 获取 Google 报告的地区
    local store_page=$(curl "$ip_flag" -sL --max-time 8 \
        'https://play.google.com' \
        -H 'accept-language: en-US;q=0.9' \
        --user-agent "$UA" 2>/dev/null || true)
    local store_region=$(echo "$store_page" | grep -o 'yVZQTb">[^(]*' | sed 's/yVZQTb">//' | head -1)
    if [ -n "$store_region" ]; then
        local code=$(country_code "$store_region")
        print_result "$label" "Google" "OK" "$code" "$DETECTED_REGION"
        return
    fi

    print_result "$label" "Google" "OK" "" "$DETECTED_REGION"
}

# ── YouTube Premium ──
check_youtube() {
    local ip_flag="$1"
    local label="$2"

    local tmpresult=$(curl "$ip_flag" -sL --max-time 10 \
        -H 'accept-language: en-US,en;q=0.9' \
        --user-agent "$UA" \
        'https://www.youtube.com/premium' 2>/dev/null || true)

    if [ -z "$tmpresult" ]; then
        print_result "$label" "YouTube" "FAIL" "" "$DETECTED_REGION"
        return
    fi

    if echo "$tmpresult" | grep -q 'www\.google\.cn'; then
        print_result "$label" "YouTube" "BLOCKED" "CN" "$DETECTED_REGION"
        return
    fi

    # YouTube 返回的 INNERTUBE_CONTEXT_GL
    local region=$(echo "$tmpresult" | grep -o '"INNERTUBE_CONTEXT_GL":"[^"]*"' | cut -d'"' -f4 | head -1)

    if echo "$tmpresult" | grep -qi 'Premium is not available in your country'; then
        print_result "$label" "YouTube" "UNAVAILABLE" "$region" "$DETECTED_REGION"
        return
    fi

    local available=$(echo "$tmpresult" | grep -qi 'ad-free' && echo 1 || echo 0)

    if [ "$available" -eq 1 ] && [ -n "$region" ]; then
        print_result "$label" "YouTube" "AVAILABLE" "$region" "$DETECTED_REGION"
    elif [ -n "$region" ]; then
        print_result "$label" "YouTube" "OK" "$region" "$DETECTED_REGION"
    else
        print_result "$label" "YouTube" "OK" "" "$DETECTED_REGION"
    fi
}

test_one() {
    local ip_flag="$1"
    local label="$2"
    detect_region "$ip_flag"
    check_google "$ip_flag" "$label"
    check_youtube "$ip_flag" "$label"
}

# ── 主流程 ──
case "${1:-}" in
    4)  test_one "-4" "IPv4" ;;
    6)  test_one "-6" "IPv6" ;;
    "")
        echo "# SvcReg = 服务自己报告的地区  |  GeoIP = OneTrust/ip-api 定位"
        echo "Network  | Service          | Status          | SvcReg | GeoIP"
        echo "--------+------------------+-----------------+--------+-------"
        test_one "-4" "IPv4"
        test_one "-6" "IPv6"
        ;;
    -h|--help|help)  usage ;;
    *)  usage ;;
esac
