#!/bin/sh

# AniList integration for ani-cli (https://anilist.co).
#
# This file is an ani-cli extension: ani-cli sources it from ext.d/ and only
# ever talks to it through the three hooks defined in ani-cli:
#
#   ext_handle_option   claims the -A / --anilist-* arguments
#   ext_help            appends the AniList section to --help
#   ext_episode_played  tracks the episode that just started playing
#
# Nothing else in ani-cli knows this file exists: deleting it (or pointing
# ANI_CLI_EXT_DIR at an empty directory) restores stock ani-cli behaviour.
#
# State lives in $XDG_CONFIG_HOME/ani-cli (default ~/.config/ani-cli):
#   anilist.conf   AniList API client id/secret   (--anilist-setup)
#   token          AniList OAuth access token     (--anilist-auth)
#   mappings.conf  scraped title -> media id map used for auto-tracking
#
# -A and --anilist-list take an optional category word (watching, planning,
# completed, rewatching, paused, dropped) to pick which AniList list they
# operate on. Auto-tracking keeps statuses in sync: finishing marks COMPLETED,
# starting a COMPLETED anime again moves it to REPEATING and bumps the rewatch
# count, and planning/paused/dropped entries resume as CURRENT.
#
# Requires jq. Uses ani-cli's curl executable when it is set.

# shellcheck disable=SC2154 # die/nth/info/dep_ch and runtime state come from ani-cli
# shellcheck disable=SC2034 # the ext_* hooks and ANI_CLI_ANILIST_OFF are read by ani-cli
# shellcheck disable=SC2016 # GraphQL documents keep their $variables literal

ANILIST_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ani-cli"
ANILIST_CLIENT_FILE="$ANILIST_CONFIG_DIR/anilist.conf"
ANILIST_TOKEN_FILE="$ANILIST_CONFIG_DIR/token"
ANILIST_MAPPINGS_FILE="$ANILIST_CONFIG_DIR/mappings.conf"

# ---------- config & token ----------

anilist_ensure_config_dir() {
    [ -d "$ANILIST_CONFIG_DIR" ] && return 0
    mkdir -p "$ANILIST_CONFIG_DIR" || die "Cannot create AniList config directory: $ANILIST_CONFIG_DIR"
}

# prints the value of a key from anilist.conf
anilist_get_config() {
    [ -f "$ANILIST_CLIENT_FILE" ] || return 0
    grep "^$1=" "$ANILIST_CLIENT_FILE" | cut -d= -f2-
}

# sets a key in anilist.conf (keeps the file private, contains the secret)
anilist_set_config() {
    anilist_ensure_config_dir
    if [ ! -f "$ANILIST_CLIENT_FILE" ]; then
        (umask 077 && : >"$ANILIST_CLIENT_FILE") || die "Cannot create $ANILIST_CLIENT_FILE"
    fi
    _al_tmp="$ANILIST_CLIENT_FILE.tmp.$$"
    grep -v "^$1=" "$ANILIST_CLIENT_FILE" >"$_al_tmp" 2>/dev/null
    printf "%s=%s\n" "$1" "$2" >>"$_al_tmp"
    mv "$_al_tmp" "$ANILIST_CLIENT_FILE" || die "Cannot write $ANILIST_CLIENT_FILE"
    chmod 600 "$ANILIST_CLIENT_FILE" 2>/dev/null
}

# prints the saved access token, nothing when there is none
anilist_get_token() {
    [ -f "$ANILIST_TOKEN_FILE" ] || return 0
    cat "$ANILIST_TOKEN_FILE"
}

anilist_save_token() {
    anilist_ensure_config_dir
    (umask 077 && printf "%s\n" "$1" >"$ANILIST_TOKEN_FILE") || die "Cannot write $ANILIST_TOKEN_FILE"
}

anilist_check_jq() {
    command -v jq >/dev/null 2>&1 || die "jq is required for AniList features. Please install jq."
}

# maps a human category word onto an AniList MediaListStatus, nothing when it
# does not name a list (canonical enum names work as well)
anilist_status_alias() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        watching | current | w) printf 'CURRENT' ;;
        planning | planned | plan | watchlist | p) printf 'PLANNING' ;;
        completed | complete | finished | finish | done | c) printf 'COMPLETED' ;;
        rewatching | rewatch | repeating | repeat | r) printf 'REPEATING' ;;
        paused | onhold | on-hold | hold | h) printf 'PAUSED' ;;
        dropped | drop | d) printf 'DROPPED' ;;
        *) printf '' ;;
    esac
}

# human label for an AniList MediaListStatus
anilist_status_label() {
    case "$1" in
        CURRENT) printf "Watching" ;;
        PLANNING) printf "Planning" ;;
        COMPLETED) printf "Completed" ;;
        REPEATING) printf "Rewatching" ;;
        PAUSED) printf "On Hold" ;;
        DROPPED) printf "Dropped" ;;
        *) printf "%s" "$1" ;;
    esac
}

# read a line without echoing it (read -s is not available in POSIX sh)
anilist_read_secret() {
    if [ -t 0 ] && stty -echo 2>/dev/null; then
        trap 'stty echo 2>/dev/null; exit 1' INT
        IFS= read -r "$1"
        stty echo 2>/dev/null
        trap - INT
        printf "\n"
    else
        IFS= read -r "$1"
    fi
}

# ---------- GraphQL ----------

# anilist_graphql_query <query> [variables json]
# prints the response body; dies with a useful message on transport,
# HTTP or GraphQL level errors
anilist_graphql_query() {
    anilist_check_jq
    _al_query="$1"
    _al_vars="$2"

    if [ -n "$_al_vars" ]; then
        _al_data=$(jq -n --arg q "$_al_query" --argjson v "$_al_vars" '{query: $q, variables: $v}')
    else
        _al_data=$(jq -n --arg q "$_al_query" '{query: $q}')
    fi
    [ -n "$_al_data" ] || die "Failed to build the AniList request payload."

    _al_token=$(anilist_get_token)
    set -- -sS -X POST -H "Content-Type: application/json" -H "Accept: application/json"
    [ -n "$_al_token" ] && set -- "$@" -H "Authorization: Bearer $_al_token"
    set -- "$@" --data-binary "$_al_data" -w '\n%{http_code}' "https://graphql.anilist.co"

    _al_raw=$(${curl_exe:-curl} "$@") || die "Network error while contacting AniList."

    _al_status=$(printf "%s" "$_al_raw" | tail -n 1)
    _al_body=$(printf "%s" "$_al_raw" | sed '$d')
    case "$_al_status" in
        2??) ;;
        401) die "AniList authentication failed (HTTP 401). Run 'ani-cli --anilist-auth' again." ;;
        429) die "AniList rate limit reached (HTTP 429). Try again in a minute." ;;
        000) die "Network error while contacting AniList." ;;
        *)
            _al_snip=$(printf "%s" "$_al_body" | cut -c 1-200)
            die "AniList API returned HTTP $_al_status: $_al_snip"
            ;;
    esac

    if printf "%s" "$_al_body" | jq -e '.errors' >/dev/null 2>&1; then
        _al_msg=$(printf "%s" "$_al_body" | jq -r '.errors[0].message // "unknown error"' 2>/dev/null)
        die "AniList API error: ${_al_msg:-unknown error}"
    fi

    printf "%s\n" "$_al_body"
}

# ---------- commands ----------

anilist_setup() {
    printf "=== AniList Setup ===\n"
    printf "1. Go to https://anilist.co/settings/developer\n"
    printf "2. Click 'Create New Client'\n"
    printf "3. Fill in:\n"
    printf "   - Name: ani-cli-tracker\n"
    printf "   - Redirect URL: https://anilist.co/api/v2/oauth/pin\n\n"

    printf "Enter your AniList Client ID: "
    IFS= read -r _al_id
    [ -n "$_al_id" ] || die "Client ID cannot be empty."

    printf "Enter your AniList Client Secret: "
    anilist_read_secret _al_secret
    [ -n "$_al_secret" ] || die "Client Secret cannot be empty."

    anilist_set_config client_id "$_al_id"
    anilist_set_config client_secret "$_al_secret"

    printf "Credentials saved to %s\n" "$ANILIST_CLIENT_FILE"
    printf "Now run 'ani-cli --anilist-auth' to authenticate.\n"
    exit 0
}

anilist_auth() {
    anilist_check_jq
    anilist_ensure_config_dir

    _al_id=$(anilist_get_config client_id)
    _al_secret=$(anilist_get_config client_secret)
    [ -n "$_al_id" ] && [ -n "$_al_secret" ] ||
        die "AniList client not configured. Run 'ani-cli --anilist-setup' first."

    printf "Visit this URL and authorize the app:\n"
    printf "https://anilist.co/api/v2/oauth/authorize?client_id=%s&response_type=code\n\n" "$_al_id"
    printf "Press Enter after authorizing..."
    IFS= read -r _al_line

    printf "Enter the authorization code from the URL: "
    IFS= read -r _al_code
    [ -n "$_al_code" ] || die "Authorization code cannot be empty."

    printf "Exchanging the code for an access token...\n"
    _al_resp=$(${curl_exe:-curl} -sS -X POST \
        -d "grant_type=authorization_code" \
        -d "client_id=$_al_id" \
        -d "client_secret=$_al_secret" \
        -d "redirect_uri=https://anilist.co/api/v2/oauth/pin" \
        -d "code=$_al_code" \
        "https://anilist.co/api/v2/oauth/token") || die "Network error during AniList authentication."

    _al_token=$(printf "%s" "$_al_resp" | jq -r '.access_token // empty' 2>/dev/null)
    if [ -z "$_al_token" ]; then
        _al_err=$(printf "%s" "$_al_resp" | jq -r '.error_description // .error // "unknown error"' 2>/dev/null)
        die "Authentication failed: ${_al_err:-malformed response}"
    fi

    anilist_save_token "$_al_token"
    printf "Authenticated with AniList.\n"
    exit 0
}

anilist_search() {
    anilist_check_jq
    [ -n "$1" ] || die "Usage: ani-cli --anilist-search <search_term>"

    printf "Searching AniList for '%s'...\n" "$1"
    _al_q='query ($search: String) { Page(page: 1, perPage: 10) { media(search: $search, type: ANIME) { id episodes status seasonYear title { romaji english } } } }'
    _al_vars=$(jq -n --arg s "$1" '{search: $s}')
    # graphql errors die in the subshell only, so propagate the failure
    _al_resp=$(anilist_graphql_query "$_al_q" "$_al_vars") || exit 1

    _al_count=$(printf "%s" "$_al_resp" | jq '.data.Page.media | length' 2>/dev/null)
    if [ -z "$_al_count" ] || [ "$_al_count" -eq 0 ]; then
        printf "No anime found matching '%s'.\n" "$1"
        exit 0
    fi

    printf "Found %s result(s):\n" "$_al_count"
    printf "%s" "$_al_resp" | jq -r '.data.Page.media[] | "[\(.id)] \(.title.romaji) (\(.title.english // "n/a")) - \(.episodes // "?") eps - \(.status) \(.seasonYear // "")"'
    exit 0
}

# anilist_update_progress <media_id> <progress> [status]
anilist_update_progress() {
    anilist_check_jq

    _al_id="$1"
    _al_progress="$2"
    _al_status="${3:-}"

    [ -n "$_al_id" ] && [ -n "$_al_progress" ] ||
        die "Usage: ani-cli --anilist-update <media_id> <progress> [status]"
    printf "%d" "$_al_id" >/dev/null 2>&1 || die "Media ID must be a number."
    printf "%d" "$_al_progress" >/dev/null 2>&1 || die "Progress must be a number."
    [ -n "$_al_status" ] || _al_status=CURRENT
    _al_status=$(anilist_status_alias "$_al_status")
    [ -n "$_al_status" ] ||
        die "Unknown status '${3:-}'. Try: watching, planning, completed, rewatching, paused, dropped."

    _al_label=$(anilist_status_label "$_al_status")
    printf "Updating AniList entry %s to episode %s (%s)...\n" "$_al_id" "$_al_progress" "$_al_label"
    _al_q='mutation ($mediaId: Int, $progress: Int, $status: MediaListStatus) { SaveMediaListEntry(mediaId: $mediaId, progress: $progress, status: $status) { id progress status } }'
    _al_vars=$(jq -n --argjson id "$_al_id" --argjson p "$_al_progress" --arg s "$_al_status" '{mediaId: $id, progress: $p, status: $s}')
    # graphql errors die in the subshell only, so propagate the failure
    _al_resp=$(anilist_graphql_query "$_al_q" "$_al_vars") || exit 1

    _al_done=$(printf "%s" "$_al_resp" | jq -r '.data.SaveMediaListEntry.progress // empty' 2>/dev/null)
    printf "Progress updated successfully%s\n" "${_al_done:+ (episode $_al_done)}"
    exit 0
}

# anilist_get_list [status]
# prints every non-custom list, or -- when a status is given -- only the
# entries of that one category
anilist_get_list() {
    anilist_check_jq
    _al_status="$1"

    _al_token=$(anilist_get_token)
    [ -n "$_al_token" ] || die "Not authenticated with AniList. Run 'ani-cli --anilist-auth' first."

    _al_viewer=$(anilist_graphql_query 'query { Viewer { id name } }') || exit 1
    _al_uid=$(printf "%s" "$_al_viewer" | jq -r '.data.Viewer.id // empty' 2>/dev/null)
    _al_uname=$(printf "%s" "$_al_viewer" | jq -r '.data.Viewer.name // "unknown"' 2>/dev/null)
    [ -n "$_al_uid" ] || die "Could not read your AniList account."

    _al_fields='lists { name status isCustomList entries { progress repeat status score media { id episodes title { romaji english } } } }'
    if [ -n "$_al_status" ]; then
        _al_q="query (\$userId: Int, \$status: MediaListStatus) { MediaListCollection(userId: \$userId, type: ANIME, status: \$status) { $_al_fields } }"
        _al_vars=$(jq -n --argjson uid "$_al_uid" --arg s "$_al_status" '{userId: $uid, status: $s}')
    else
        _al_q="query (\$userId: Int) { MediaListCollection(userId: \$userId, type: ANIME) { $_al_fields } }"
        _al_vars=$(jq -n --argjson uid "$_al_uid" '{userId: $uid}')
    fi
    # graphql errors die in the subshell only, so propagate the failure
    _al_resp=$(anilist_graphql_query "$_al_q" "$_al_vars") || exit 1
    printf "%s" "$_al_resp" | jq -e '.data.MediaListCollection' >/dev/null 2>&1 ||
        die "Could not fetch your AniList lists."

    if [ -n "$_al_status" ]; then
        _al_label=$(anilist_status_label "$_al_status")
        printf "AniList %s list for %s:\n" "$_al_label" "$_al_uname"
    else
        printf "AniList list for %s:\n" "$_al_uname"
    fi
    printf "%s" "$_al_resp" | jq -r '
        (.data.MediaListCollection.lists // [])[]
        | select((.isCustomList // false) | not)
        | (.entries // []) as $e
        | select(($e | length) > 0)
        | "\(.name // .status // "List") (\($e | length)):"
        , ($e[] | "  - \(.media.title.english // .media.title.romaji // "Unknown title") (EP \(.progress)/\(.media.episodes // "?"))\(if ((.repeat // 0) > 0) then " [rewatched \(.repeat)x]" else "" end)\(if ((.score // 0) > 0) then " ★\(.score)" else "" end)")' ||
        die "Failed to format your AniList lists."
    exit 0
}

# ---------- title mappings ----------

# mapping keys are the scraped title without its " (N episodes)" suffix
anilist_map_key() {
    printf "%s" "$1" | sed 's/ ([0-9][0-9]* episodes)$//; s/|//g'
}

# anilist_save_mapping <scraped title> <media id>
anilist_save_mapping() {
    _al_key=$(anilist_map_key "$1")
    _al_id="$2"
    [ -n "$_al_key" ] && [ -n "$_al_id" ] || return 1
    anilist_ensure_config_dir

    _al_tmp="$ANILIST_MAPPINGS_FILE.tmp.$$"
    : >"$_al_tmp" || return 1
    _al_found=0
    if [ -f "$ANILIST_MAPPINGS_FILE" ]; then
        while IFS= read -r _al_line; do
            if [ "${_al_line%%|*}" = "$_al_key" ]; then
                printf "%s|%s\n" "$_al_key" "$_al_id" >>"$_al_tmp"
                _al_found=1
            else
                printf "%s\n" "$_al_line" >>"$_al_tmp"
            fi
        done <"$ANILIST_MAPPINGS_FILE"
    fi
    [ "$_al_found" = 1 ] || printf "%s|%s\n" "$_al_key" "$_al_id" >>"$_al_tmp"
    mv "$_al_tmp" "$ANILIST_MAPPINGS_FILE"
}

# prints the media id mapped to <scraped title>, nothing when unknown
anilist_get_mapped_id() {
    [ -f "$ANILIST_MAPPINGS_FILE" ] || return 0
    _al_key=$(anilist_map_key "$1")
    while IFS= read -r _al_line; do
        if [ "${_al_line%%|*}" = "$_al_key" ] || { [ -n "$_al_key" ] && [ "${_al_line%%|*}" = "$1" ]; }; then
            _al_id="${_al_line#*|}"
            [ -n "$_al_id" ] && [ "$_al_id" != "$_al_line" ] && printf "%s" "$_al_id"
            return 0
        fi
    done <"$ANILIST_MAPPINGS_FILE"
}

# ---------- title matching ----------

# lowercase and drop everything that is not a letter or digit
anilist_norm() {
    printf "%s" "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^[:alnum:]]//g'
}

# prints the id of the first AniList search result for $1, nothing when empty
anilist_first_media_id() {
    _al_q='query ($search: String) { Page(page: 1, perPage: 1) { media(search: $search, type: ANIME) { id } } }'
    _al_vars=$(jq -n --arg s "$1" '{search: $s}')
    # a failed lookup is not fatal here, the caller falls back to prompting
    _al_resp=$(anilist_graphql_query "$_al_q" "$_al_vars") || return 0
    printf "%s" "$_al_resp" | jq -r '.data.Page.media[0].id // empty' 2>/dev/null
}

# prints a media id only when a result's title matches $1 exactly (ignoring
# case, punctuation and spacing); never guesses
anilist_match_title() {
    _al_norm=$(anilist_norm "$1")
    [ -n "$_al_norm" ] || return 0

    _al_q='query ($search: String) { Page(page: 1, perPage: 10) { media(search: $search, type: ANIME) { id title { romaji english } } } }'
    _al_vars=$(jq -n --arg s "$1" '{search: $s}')
    _al_resp=$(anilist_graphql_query "$_al_q" "$_al_vars" 2>/dev/null) || return 0
    _al_rows=$(printf "%s" "$_al_resp" | jq -r '.data.Page.media[]? | [.id, (.title.romaji // ""), (.title.english // "")] | @tsv' 2>/dev/null)
    [ -n "$_al_rows" ] || return 0

    while IFS="$(printf '\t')" read -r _al_cid _al_romaji _al_english; do
        _al_r=$(anilist_norm "$_al_romaji")
        _al_e=$(anilist_norm "$_al_english")
        if [ "$_al_r" = "$_al_norm" ] || [ "$_al_e" = "$_al_norm" ]; then
            printf "%s" "$_al_cid"
            return 0
        fi
    done <<EOF
$_al_rows
EOF
}

# ---------- progress tracking ----------

# anilist_push_progress <media id> <progress>
# background worker. One authenticated query reads the episode count plus the
# current list entry (status/progress/rewatch count), then the entry is saved
# with a sensible status for the new progress:
#   - no entry            -> CURRENT
#   - COMPLETED + earlier episode -> REPEATING, rewatch count +1 (a rewatch)
#   - REPEATING at the last episode -> COMPLETED (rewatch finished)
#   - CURRENT at the last episode   -> COMPLETED (first watch finished)
#   - PLANNING / PAUSED / DROPPED   -> CURRENT (started/s/resumed)
anilist_push_progress() {
    _al_id="$1"
    _al_progress="$2"

    _al_q='query ($id: Int) { Media(id: $id, type: ANIME) { episodes mediaListEntry { status progress repeat } } }'
    _al_vars=$(jq -n --argjson id "$_al_id" '{id: $id}')
    _al_resp=$(anilist_graphql_query "$_al_q" "$_al_vars" 2>/dev/null) || return 1

    # decide the new (status, progress, repeat) in one place
    _al_new=$(printf "%s" "$_al_resp" | jq -c --argjson p "$_al_progress" '
        ($p | tonumber) as $p
        | (.data.Media.episodes // null) as $ep
        | (.data.Media.mediaListEntry // {}) as $e
        | (($e.progress // 0) | tonumber) as $cur
        | (($e.repeat // 0) | tonumber) as $rpt
        | if $e.status == null then
            { status: "CURRENT", progress: $p, repeat: 0 }
          elif $e.status == "COMPLETED" and $p < $cur then
            { status: "REPEATING", progress: $p, repeat: ($rpt + 1) }
          elif $e.status == "REPEATING" and $ep != null and $p >= $ep then
            { status: "COMPLETED", progress: $ep, repeat: $rpt }
          elif $e.status == "CURRENT" and $ep != null and $p >= $ep then
            { status: "COMPLETED", progress: $ep, repeat: $rpt }
          elif $e.status == "PLANNING" then
            { status: "CURRENT", progress: $p, repeat: $rpt }
          elif $e.status == "PAUSED" or $e.status == "DROPPED" then
            { status: "CURRENT", progress: $p, repeat: $rpt }
          else
            { status: $e.status, progress: $p, repeat: $rpt }
          end' 2>/dev/null) || return 1

    _al_nstatus=$(printf "%s" "$_al_new" | jq -r '.status' 2>/dev/null)
    _al_nprogress=$(printf "%s" "$_al_new" | jq -r '.progress' 2>/dev/null)
    _al_nrepeat=$(printf "%s" "$_al_new" | jq -r '.repeat' 2>/dev/null)
    [ -n "$_al_nstatus" ] || return 1

    _al_q='mutation ($mediaId: Int, $progress: Int, $status: MediaListStatus, $repeat: Int) { SaveMediaListEntry(mediaId: $mediaId, progress: $progress, status: $status, repeat: $repeat) { id progress status repeat } }'
    _al_vars=$(jq -n --argjson id "$_al_id" --argjson p "$_al_nprogress" --arg s "$_al_nstatus" --argjson r "$_al_nrepeat" '{mediaId: $id, progress: $p, status: $s, repeat: $r}')
    anilist_graphql_query "$_al_q" "$_al_vars" >/dev/null || return 1
}

# called by ani-cli when an episode starts: <title> <episode number>
anilist_auto_track() {
    _al_title="$1"
    _al_ep="$2"
    [ -n "$_al_title" ] && [ -n "$_al_ep" ] || return 0
    [ "${ANI_CLI_ANILIST_OFF:-0}" = "1" ] && return 0

    # not authenticated -> the feature was never set up, stay quiet
    _al_token=$(anilist_get_token)
    [ -n "$_al_token" ] || return 0
    command -v jq >/dev/null 2>&1 || {
        printf "AniList: jq not found, cannot track progress.\n" >&2
        return 0
    }
    _al_num=$(printf "%d" "$_al_ep" 2>/dev/null) || {
        printf "AniList: episode '%s' is not a number, not tracking '%s'.\n" "$_al_ep" "$_al_title" >&2
        return 0
    }

    # 1. the id the watchlist selector handed over to this process
    _al_id=""
    if [ -n "${ANI_CLI_ANILIST_ID:-}" ]; then
        _al_id="$ANI_CLI_ANILIST_ID"
        unset ANI_CLI_ANILIST_ID
        anilist_save_mapping "$_al_title" "$_al_id"
    fi
    # 2. a mapping saved on an earlier run
    [ -n "$_al_id" ] || _al_id=$(anilist_get_mapped_id "$_al_title")
    # 3. exact title match against AniList, remembered for next time
    if [ -z "$_al_id" ]; then
        _al_id=$(anilist_match_title "$_al_title")
        [ -n "$_al_id" ] && anilist_save_mapping "$_al_title" "$_al_id"
    fi
    # 4. ask the user once (interactive runs only)
    if [ -z "$_al_id" ]; then
        if [ -t 0 ]; then
            printf "AniList: no match for '%s'.\n" "$_al_title"
            printf "Type the title as spelled on AniList (Enter skips tracking): "
            IFS= read -r _al_choice
            if [ -z "$_al_choice" ]; then
                printf "AniList: tracking skipped for '%s'.\n" "$_al_title"
            else
                _al_id=$(anilist_first_media_id "$_al_choice")
                if [ -n "$_al_id" ]; then
                    anilist_save_mapping "$_al_title" "$_al_id"
                    printf "AniList: mapping saved, tracking '%s' from now on.\n" "$_al_title"
                else
                    printf "AniList: nothing found for '%s', skipped.\n" "$_al_choice" >&2
                fi
            fi
        else
            printf "AniList: no known match for '%s', not tracked.\n" "$_al_title" >&2
        fi
    fi
    [ -n "$_al_id" ] || return 0
    printf "%d" "$_al_id" >/dev/null 2>&1 || return 0

    printf "AniList: tracking '%s' episode %s\n" "$_al_title" "$_al_num"
    anilist_push_progress "$_al_id" "$_al_num" >/dev/null 2>&1 &
}

# ---------- watchlist selector ----------

# -A [status]: pick an entry from an AniList list and continue with it.
# Defaults to 'Watching'. Picking from 'Completed' restarts the show as a
# rewatch from episode 1 (the tracker flips it to REPEATING and bumps the
# rewatch count when the episode starts playing).
anilist_select_watchlist() {
    anilist_check_jq
    _al_status="${1:-CURRENT}"
    _al_label=$(anilist_status_label "$_al_status")

    _al_token=$(anilist_get_token)
    [ -n "$_al_token" ] || die "Not authenticated with AniList. Run 'ani-cli --anilist-auth' first."
    dep_ch "$menu_program"

    printf "Fetching your AniList '%s' list...\n" "$_al_label"
    _al_viewer=$(anilist_graphql_query 'query { Viewer { id name } }') || exit 1
    _al_uid=$(printf "%s" "$_al_viewer" | jq -r '.data.Viewer.id // empty' 2>/dev/null)
    _al_uname=$(printf "%s" "$_al_viewer" | jq -r '.data.Viewer.name // "you"' 2>/dev/null)
    [ -n "$_al_uid" ] || die "Could not read your AniList account."
    printf "User: %s\n" "$_al_uname"

    _al_q='query ($userId: Int, $status: MediaListStatus) { MediaListCollection(userId: $userId, type: ANIME, status: $status) { lists { entries { progress repeat media { id episodes title { romaji english } } } } } }'
    _al_vars=$(jq -n --argjson uid "$_al_uid" --arg s "$_al_status" '{userId: $uid, status: $s}')
    # graphql errors die in the subshell only, so propagate the failure
    _al_resp=$(anilist_graphql_query "$_al_q" "$_al_vars") || exit 1
    _al_rows=$(printf "%s" "$_al_resp" | jq -r '
        [((.data.MediaListCollection // {}).lists // [])[] | (.entries // [])[]]
        | unique_by(.media.id)[]
        | "\(.media.id)\t\(.media.title.english // .media.title.romaji // "Unknown title") (EP \(.progress)/\(.media.episodes // "?")\(if ((.repeat // 0) > 0) then ", rewatches \(.repeat)" else "" end))"' 2>/dev/null)
    [ -n "$_al_rows" ] || die "Your AniList '$_al_label' list is empty."

    _al_sel=$(printf "%s\n" "$_al_rows" | nl -w 2 | sed 's/^[[:space:]]*//' | nth "Select anime: ")
    if [ -z "$_al_sel" ]; then
        printf "No anime selected.\n"
        exit 1
    fi

    _al_media_id=$(printf "%s" "$_al_sel" | cut -f1)
    _al_display=$(printf "%s" "$_al_sel" | cut -f2)
    _al_title=$(printf "%s" "$_al_display" | sed 's/ (EP [^)]*)$//')
    _al_progress=$(printf "%s" "$_al_display" | sed -n 's/.*(EP \([0-9][0-9]*\)\/.*/\1/p')
    _al_total=$(printf "%s" "$_al_display" | sed -n 's|.*/\([0-9][0-9]*\)[,)].*$|\1|p')

    if [ "$_al_status" = "COMPLETED" ]; then
        _al_next=1
        printf "Rewatching '%s' from episode 1...\n" "$_al_title"
    else
        if [ -z "$_al_progress" ]; then
            printf "Could not read your progress for '%s', starting at episode 1.\n" "$_al_title"
            _al_progress=0
        fi
        _al_next=$((_al_progress + 1))
        if [ -n "$_al_total" ] && [ "$_al_next" -gt "$_al_total" ]; then
            die "You already watched all $_al_total episodes of '$_al_title'."
        fi
        printf "Next episode of '%s': %s\n" "$_al_title" "$_al_next"
    fi

    # hand the exact media id to the playback process so tracking never guesses
    export ANI_CLI_ANILIST_ID="$_al_media_id"
    set -- -e "$_al_next" "$_al_title"
    # carry over the flags that were given alongside -A
    [ "$mode" = "dub" ] && set -- --dub "$@"
    [ "$quality" != "best" ] && set -- -q "$quality" "$@"
    [ "$skip_intro" = "1" ] && set -- --skip "$@"
    [ "$no_detach" = "1" ] && set -- --no-detach "$@"
    [ "$exit_after_play" = "1" ] && set -- --exit-after-play "$@"
    [ "$menu_program" != "${ANI_CLI_MENU:-fzf}" ] && set -- "--$menu_program" "$@"
    exec "$0" "$@"
}

# ---------- hooks ----------

ext_handle_option() {
    case "$1" in
        -A | --A | --anilist-watch)
            _al_cat=$(anilist_status_alias "${2:-}")
            if [ -n "$_al_cat" ]; then
                ext_consumed=2
                anilist_select_watchlist "$_al_cat"
            else
                ext_consumed=1
                anilist_select_watchlist CURRENT
            fi
            ;;
        --anilist-watching | --anilist-current)
            ext_consumed=1
            anilist_select_watchlist CURRENT
            ;;
        --anilist-planning)
            ext_consumed=1
            anilist_select_watchlist PLANNING
            ;;
        --anilist-completed | --anilist-finished)
            ext_consumed=1
            anilist_select_watchlist COMPLETED
            ;;
        --anilist-rewatching | --anilist-repeating)
            ext_consumed=1
            anilist_select_watchlist REPEATING
            ;;
        --anilist-paused)
            ext_consumed=1
            anilist_select_watchlist PAUSED
            ;;
        --anilist-dropped)
            ext_consumed=1
            anilist_select_watchlist DROPPED
            ;;
        --anilist-setup)
            ext_consumed=1
            anilist_setup
            ;;
        --anilist-auth)
            ext_consumed=1
            anilist_auth
            ;;
        --anilist-search)
            ext_consumed=$#
            shift
            [ $# -ge 1 ] || die "Usage: ani-cli --anilist-search <search_term>"
            anilist_search "$*"
            ;;
        --anilist-update)
            ext_consumed=$#
            shift
            [ $# -ge 2 ] || die "Usage: ani-cli --anilist-update <media_id> <progress> [status]"
            anilist_update_progress "$1" "$2" "${3:-}"
            ;;
        --anilist-list | anilist-list)
            _al_cat=$(anilist_status_alias "${2:-}")
            if [ -n "$_al_cat" ]; then
                ext_consumed=2
                anilist_get_list "$_al_cat"
            else
                ext_consumed=1
                anilist_get_list ""
            fi
            ;;
        --anilist-off)
            ext_consumed=1
            ANI_CLI_ANILIST_OFF=1
            printf "AniList tracking disabled for this run.\n"
            ;;
        *)
            return 1
            ;;
    esac
}

ext_help() {
    printf "
    AniList commands (ext.d/anilist.sh):
      -A, --A [status]           Continue from an AniList list (see below)
      --anilist-watching         Continue from 'Watching' (same as -A)
      --anilist-planning         Continue from 'Planning'
      --anilist-completed        Continue from 'Completed' (starts a rewatch)
      --anilist-rewatching       Continue from 'Rewatching'
      --anilist-paused           Continue from 'Paused' (on hold)
      --anilist-dropped          Continue from 'Dropped'
      --anilist-list [status]    Show your anime list (or just one category)
      --anilist-setup            Configure your AniList API client (first run)
      --anilist-auth             Authenticate with AniList
      --anilist-search <term>    Search for anime on AniList
      --anilist-update <id> <ep> [status]
                                 Update episode progress (default status CURRENT)
      --anilist-off              Do not touch AniList during this run

    Status: watching|current, planning, completed|finished, rewatching,
      paused, dropped. Starting a finished anime again moves it to 'Rewatching'
      and bumps the rewatch count automatically; finishing it marks it
      COMPLETED again.

    Tracking:
      Once --anilist-setup and --anilist-auth are done, episodes that start
      playing are pushed to AniList automatically. Titles are matched through
      mappings.conf (a match is asked for once, then remembered). Needs jq.
    \n"
}

ext_episode_played() {
    anilist_auto_track "$1" "$2"
}
