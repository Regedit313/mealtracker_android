
#!/data/data/com.termux/files/usr/bin/bash
# MealTracker Android - donnees conservees hors de mealtracker_android.
set -u
set -o pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$HOME/storage/shared/mealtracker_data"
JSON="$DATA_DIR/meals.json"

pause_error() {
    printf '\nAppuie sur Entree pour revenir...'
    read -r _ || true
}

format_time() { date -d "@$1" '+%d/%m/%Y - %H:%M'; }

format_duration() {
    local s=$1 d h m
    (( s < 0 )) && s=0
    d=$((s / 86400))
    h=$(((s % 86400) / 3600))
    m=$(((s % 3600) / 60))
    if (( d > 0 )); then
        printf '%d j %d h %d min' "$d" "$h" "$m"
    elif (( h > 0 )); then
        printf '%d h %d min' "$h" "$m"
    else
        printf '%d min' "$m"
    fi
}

# Accepte : 23/12/2003, 23 12 2003, 23122003.
# Renvoie la date au format AAAA-MM-JJ.
parse_day() {
    local input="$1" digits dd mm yyyy iso normalized
    if [[ "$input" =~ ^[0-9]{8}$ ]]; then
        digits="$input"
    elif [[ "$input" =~ ^[0-9]{2}/[0-9]{2}/[0-9]{4}$ ]]; then
        digits="${input//\//}"
    elif [[ "$input" =~ ^[0-9]{2}[[:space:]]+[0-9]{2}[[:space:]]+[0-9]{4}$ ]]; then
        digits="${input//[[:space:]]/}"
    else
        return 1
    fi
    dd="${digits:0:2}"
    mm="${digits:2:2}"
    yyyy="${digits:4:4}"
    iso="$yyyy-$mm-$dd"
    normalized=$(date -d "$iso" '+%Y-%m-%d' 2>/dev/null) || return 1
    [[ "$normalized" == "$iso" ]] || return 1
    printf '%s' "$iso"
}

# Accepte : 23:45, 23 45, 23h45, 2345.
# Renvoie HH:MM (24 h).
parse_hour() {
    local input="$1" digits hh mm
    if [[ "$input" =~ ^[0-9]{4}$ ]]; then
        digits="$input"
    elif [[ "$input" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
        digits="${input//:/}"
    elif [[ "$input" =~ ^[0-9]{2}[hH][0-9]{2}$ ]]; then
        digits="${input//[hH]/}"
    elif [[ "$input" =~ ^[0-9]{2}[[:space:]]+[0-9]{2}$ ]]; then
        digits="${input//[[:space:]]/}"
    else
        return 1
    fi
    hh="${digits:0:2}"
    mm="${digits:2:2}"
    (( 10#$hh <= 23 && 10#$mm <= 59 )) || return 1
    printf '%s:%s' "$hh" "$mm"
}

valid_json() {
    jq -e '
        .version == 1 and
        (.interval_hours | type == "number" and . == floor and . >= 1 and . <= 720) and
        (.meals | type == "array") and
        (all(.meals[];
            (.timestamp | type == "number" and . == floor) and
            (.bad_sessions | type == "array") and
            (all(.bad_sessions[];
                . as $s |
                ($s.start | type == "number" and . == floor) and
                ($s.end == null or
                    ($s.end | type == "number" and . == floor and . >= $s.start)) and
                (if $s.end == null then $s.end_reason == null
                 else ($s.end_reason == "manual" or $s.end_reason == "new_meal") end)
            ))
        ))
    ' "$1" >/dev/null 2>&1
}

init_data() {
    if [[ ! -d "$HOME/storage/shared" ]]; then
        echo 'Stockage inaccessible : lance termux-setup-storage.'
        return 1
    fi
    mkdir -p "$DATA_DIR" || return 1
    if [[ ! -e "$JSON" ]]; then
        local tmp
        tmp=$(mktemp "$DATA_DIR/.initial.XXXXXXXX") || return 1
        if ! printf '{"version":1,"interval_hours":12,"meals":[]}\n' > "$tmp" ||
           ! mv -n "$tmp" "$JSON"; then
            rm -f "$tmp"
            return 1
        fi
        rm -f "$tmp"
    fi
    if ! valid_json "$JSON"; then
        echo "ERREUR : historique JSON invalide : $JSON"
        echo "Aucune donnee effacee. Sauvegarde : $JSON.bak"
        return 1
    fi
}

# Ecriture atomique et sauvegarde de la version precedente.
commit_json() {
    local tmp backup
    tmp=$(mktemp "$DATA_DIR/.new.XXXXXXXX") || return 1
    if ! jq "$@" "$JSON" > "$tmp" || ! valid_json "$tmp"; then
        rm -f "$tmp"
        echo "ERREUR : l'enregistrement a echoue. Historique inchange."
        return 1
    fi
    backup=$(mktemp "$DATA_DIR/.bak.XXXXXXXX") || {
        rm -f "$tmp"
        return 1
    }
    if ! cp "$JSON" "$backup" || ! mv -f "$backup" "$JSON.bak"; then
        rm -f "$tmp" "$backup"
        echo 'ERREUR : sauvegarde impossible. Historique inchange.'
        return 1
    fi
    if ! mv -f "$tmp" "$JSON"; then
        rm -f "$tmp"
        echo 'ERREUR : impossible de mettre a jour le JSON.'
        return 1
    fi
}

latest_meal() {
    jq -r 'if (.meals | length) == 0 then empty else .meals[-1].timestamp end' "$JSON"
}

bad_active() {
    jq -e '(.meals | length) > 0 and
        (.meals[-1].bad_sessions | length) > 0 and
        (.meals[-1].bad_sessions[-1].end == null)' "$JSON" >/dev/null 2>&1
}

record_meal_at() {
    local timestamp="$1" now last last_event
    now=$(date +%s)
    last=$(latest_meal)

    if (( timestamp > now )); then
        echo 'Impossible : le repas est dans le futur.'
        return 1
    fi
    if [[ -n "$last" ]] && (( timestamp <= last )); then
        echo 'Impossible : heure anterieure ou egale au dernier repas.'
        return 1
    fi
    if [[ -n "$last" ]]; then
        last_event=$(jq -r '
            [.meals[-1].bad_sessions[]? | .start, (.end // .start)] |
            if length == 0 then 0 else max end
        ' "$JSON")
        if (( timestamp < last_event )); then
            echo 'Impossible : un evenement BAD a eu lieu apres cette heure.'
            echo 'Le repas ne doit pas modifier retroactivement cet evenement.'
            return 1
        fi
    fi

    if bad_active; then
        commit_json --argjson t "$timestamp" '
            .meals[-1].bad_sessions[-1].end = $t |
            .meals[-1].bad_sessions[-1].end_reason = "new_meal" |
            .meals += [{"timestamp":$t,"bad_sessions":[]}]
        '
    else
        commit_json --argjson t "$timestamp" '
            .meals += [{"timestamp":$t,"bad_sessions":[]}]
        '
    fi
}

record_manual() {
    local input day hour timestamp
    clear 2>/dev/null || true
    echo 'Ajouter un repas en retard'
    echo 'Date (JJ MM AAAA, Entree = aujourd hui)'
    read -r -p 'Date : ' input || return
    if [[ -z "$input" ]]; then
        day=$(date +%F)
    else
        day=$(parse_day "$input") || {
            echo 'Date invalide.'
            pause_error
            return
        }
    fi
    echo 'Heure obligatoire (HH MM)'
    read -r -p 'Heure : ' input || return
    hour=$(parse_hour "$input") || {
        echo 'Heure invalide.'
        pause_error
        return
    }
    timestamp=$(date -d "$day $hour:00" +%s 2>/dev/null) || {
        echo 'Date ou heure impossible.'
        pause_error
        return
    }
    if [[ "$(date -d "@$timestamp" '+%F %H:%M')" != "$day $hour" ]]; then
        echo 'Heure locale inexistante (changement d heure).'
        pause_error
        return
    fi
    record_meal_at "$timestamp" || pause_error
}

toggle_bad() {
    local now
    now=$(date +%s)
    if [[ -z "$(latest_meal)" ]]; then
        echo "Enregistre d'abord un repas."
        pause_error
        return
    fi
    if bad_active; then
        commit_json --argjson t "$now" '
            .meals[-1].bad_sessions[-1].end = $t |
            .meals[-1].bad_sessions[-1].end_reason = "manual"
        ' || pause_error
    else
        commit_json --argjson t "$now" '
            .meals[-1].bad_sessions += [
                {"start":$t,"end":null,"end_reason":null}
            ]
        ' || pause_error
    fi
}

show_menu() {
    local now last interval next diff started
    clear 2>/dev/null || true
    now=$(date +%s)
    last=$(latest_meal)
    interval=$(jq -r '.interval_hours' "$JSON")

    echo 'mealtracker_android'
    echo '-------------------'
    if [[ -z "$last" ]]; then
        echo 'Dernier repas : Aucun'
        echo 'Temps depuis repas : --'
    else
        printf 'Dernier repas : %s' "$(format_time "$last")"
        bad_active && printf ' [BAD]'
        printf '\nTemps depuis repas : %s\n' "$(format_duration "$((now - last))")"
    fi
    if bad_active; then
        echo
        started=$(jq -r '.meals[-1].bad_sessions[-1].start' "$JSON")
        printf 'BAD depuis : %s\n' "$(format_time "$started")"
        printf 'Temps en BAD : %s\n' "$(format_duration "$((now - started))")"
    fi
    echo
    printf 'Intervalle : %s h\n' "$interval"
    if [[ -z "$last" ]]; then
        echo 'Prochain repas prevu : --'
        echo 'Prochain repas dans : --'
    else
        next=$((last + interval * 3600))
        diff=$((next - now))
        printf 'Prochain repas prevu : %s\n' "$(format_time "$next")"
        if (( diff >= 0 )); then
            printf 'Prochain repas dans : %s\n' "$(format_duration "$diff")"
        else
            printf 'Delai depasse de : %s\n' "$(format_duration "$((-diff))")"
        fi
    fi
    echo
    echo '1) Enregistrer un repas'
    echo '3) Ajouter un repas manuellement'
    if bad_active; then echo '5) Terminer BAD'; else echo '5) Demarrer BAD'; fi
    echo '7) Historique'
    echo '8) Actualiser'
    echo '9) Setup / Update'
    echo '0) Quitter'
    echo
}

history_view() {
    local start="$1" end="$2" label="$3"
    local from to nextday raw view
    local ts priority event secs reason
    local meals=0 bads=0 page total last answer

    from=$(date -d "$start 00:00:00" +%s) || return 1
    nextday=$(date -d "$end +1 day" +%F) || return 1
    to=$(date -d "$nextday 00:00:00" +%s) || return 1

    raw=$(mktemp) || return 1
    view=$(mktemp) || { rm -f "$raw"; return 1; }

    if ! jq -r --argjson a "$from" --argjson b "$to" '
        .meals[] |
        (if .timestamp >= $a and .timestamp < $b
         then [.timestamp,1,"MEAL",0,""] | @tsv else empty end),
        (.bad_sessions[] |
            (if .start >= $a and .start < $b
             then [.start,2,"START",0,""] | @tsv else empty end),
            (if .end != null and .end >= $a and .end < $b
             then [.end,0,"END",(.end-.start),.end_reason] | @tsv
             else empty end)
        )
    ' "$JSON" | sort -s -t $'\t' -k1,1n -k2,2n > "$raw"; then
        rm -f "$raw" "$view"
        echo 'Erreur de lecture de l historique.'
        pause_error
        return 1
    fi

    {
        echo "Historique : $label"
        echo "Du $(date -d "$start" +%d/%m/%Y) au $(date -d "$end" +%d/%m/%Y)"
        echo '--------------------------------'
    } > "$view"

    while IFS=$'\t' read -r ts priority event secs reason; do
        [[ -z "$ts" ]] && continue
        case "$event" in
            MEAL)
                printf '%s : Repas\n' "$(format_time "$ts")" >> "$view"
                ((meals += 1))
                ;;
            START)
                printf '%s : BAD demarre\n' "$(format_time "$ts")" >> "$view"
                ((bads += 1))
                ;;
            END)
                if [[ "$reason" == manual ]]; then
                    reason='manuel'
                else
                    reason='nouveau repas'
                fi
                printf '%s : BAD termine (%s)\n' "$(format_time "$ts")" "$reason" >> "$view"
                printf '   Duree : %s\n' "$(format_duration "$secs")" >> "$view"
                ;;
        esac
    done < "$raw"

    {
        echo '--------------------------------'
        echo "Repas : $meals | BAD demarres : $bads"
    } >> "$view"
    rm -f "$raw"

    total=$(wc -l < "$view")
    page=1
    while (( page <= total )); do
        clear 2>/dev/null || true
        last=$((page + 22))
        (( last > total )) && last=$total
        sed -n "${page},${last}p" "$view"
        if (( last == total )); then
            pause_error
            break
        fi
        echo
        read -r -p 'Entree : suite | q : retour : ' answer || break
        [[ "$answer" == q || "$answer" == Q ]] && break
        page=$((last + 1))
    done
    rm -f "$view"
}

history_menu() {
    local choice today first start end input
    while true; do
        clear 2>/dev/null || true
        echo 'Historique des repas'
        echo '1) 7 derniers jours'
        echo '2) 30 derniers jours'
        echo "3) Tout l'historique"
        echo '4) Choisir une periode'
        echo '0) Retour'
        echo
        read -r -p 'Choix : ' choice || return

        today=$(date +%F)
        first=$(jq -r '
            if (.meals | length) == 0
            then empty else .meals[0].timestamp end
        ' "$JSON")
        [[ -n "$first" ]] && first=$(date -d "@$first" +%F)

        case "$choice" in
            1)
                start=$(date -d "$today -6 days" +%F)
                history_view "$start" "$today" '7 jours'
                ;;
            2)
                start=$(date -d "$today -29 days" +%F)
                history_view "$start" "$today" '30 jours'
                ;;
            3)
                if [[ -n "$first" ]]; then
                    history_view "$first" "$today" 'complet'
                else
                    echo 'Historique vide.'
                    pause_error
                fi
                ;;
            4)
                echo 'Date : JJ MM AAAA (Entree = limite automatique)'
                read -r -p 'A partir du : ' input || return
                if [[ -z "$input" ]]; then
                    start="$first"
                else
                    start=$(parse_day "$input") || {
                        echo 'Date de debut invalide.'
                        pause_error
                        continue
                    }
                fi
                read -r -p "Jusqu'au    : " input || return
                if [[ -z "$input" ]]; then
                    end="$today"
                else
                    end=$(parse_day "$input") || {
                        echo 'Date de fin invalide.'
                        pause_error
                        continue
                    }
                fi
                if [[ -z "$start" ]]; then
                    echo 'Historique vide.'
                    pause_error
                    continue
                fi
                if [[ "$end" < "$start" ]]; then
                    echo 'La fin doit etre posterieure ou egale au debut.'
                    pause_error
                    continue
                fi
                history_view "$start" "$end" 'periode choisie'
                ;;
            0) return ;;
            *) echo 'Choix invalide.'; pause_error ;;
        esac
    done
}

interval_menu() {
    local choice hours
    while true; do
        clear 2>/dev/null || true
        printf 'Intervalle actuel : %s h\n' "$(jq -r '.interval_hours' "$JSON")"
        echo '1) 6 heures'
        echo '2) 8 heures'
        echo '3) 10 heures'
        echo '4) 12 heures'
        echo '5) Autre duree en heures'
        echo '0) Retour'
        read -r -p 'Choix : ' choice || return
        case "$choice" in
            1) hours=6 ;;
            2) hours=8 ;;
            3) hours=10 ;;
            4) hours=12 ;;
            5)
                read -r -p 'Heures (1 a 720) : ' hours || return
                if [[ ! "$hours" =~ ^[0-9]{1,3}$ ]] ||
                   (( 10#$hours < 1 || 10#$hours > 720 )); then
                    echo 'Duree invalide.'
                    pause_error
                    continue
                fi
                hours=$((10#$hours))
                ;;
            0) return ;;
            *) echo 'Choix invalide.'; pause_error; continue ;;
        esac
        if commit_json --argjson hours "$hours" '.interval_hours = $hours'; then
            return
        else
            pause_error
        fi
    done
}

setup_menu() {
    local choice
    while true; do
        clear 2>/dev/null || true
        echo 'Setup / Update'
        echo '1) Changer intervalle entre repas'
        echo '2) Run Setup / Update'
        echo '0) Retour'
        read -r -p 'Choix : ' choice || return
        case "$choice" in
            1) interval_menu ;;
            2) bash "$APP_DIR/mealtracker_setup.sh" ;;
            0) return ;;
            *) echo 'Choix invalide.'; pause_error ;;
        esac
    done
}

main() {
    local choice
    if ! command -v jq >/dev/null 2>&1; then
        echo 'jq manquant. Lance mealtracker_setup.sh une seule fois.'
        pause_error
        return 1
    fi
    init_data || { pause_error; return 1; }
    while true; do
        show_menu
        read -r -p 'Choix : ' choice || break
        case "$choice" in
            1) record_meal_at "$(date +%s)" || pause_error ;;
            3) record_manual ;;
            5) toggle_bad ;;
            7) history_menu ;;
            8) : ;;
            9) setup_menu ;;
            0|"") break ;;
            *) echo 'Choix invalide.'; pause_error ;;
        esac
    done
}

main "$@"

