
#!/data/data/com.termux/files/usr/bin/bash
# MealTracker Boost - application Termux, donnees persistantes separees.
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

# JJ/MM/AAAA, JJ MM AAAA ou JJMMAAAA -> AAAA-MM-JJ.
parse_day() {
    local input="$1" digits dd mm yyyy iso

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

    [[ "$(date -d "$iso" +%F 2>/dev/null)" == "$iso" ]] || return 1
    printf '%s' "$iso"
}

# HH:MM, HH MM, HHhMM ou HHMM -> HH:MM.
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
        .version == 2 and
        (.interval_hours |
            type == "number" and . == floor and . >= 1 and . <= 720) and
        (.boost_effect_hours |
            type == "number" and . == floor and . >= 1 and . <= 720) and
        (.boost_display_hours |
            type == "number" and . == floor and . >= 1 and . <= 720) and
        (.meals | type == "array") and
        (.boosts | type == "array") and
        (all(.meals[];
            (.timestamp | type == "number" and . == floor) and
            (.with_boost | type == "boolean")
        )) and
        (all(.boosts[];
            (.timestamp | type == "number" and . == floor) and
            (.with_meal | type == "boolean")
        )) and
        ([.meals[].timestamp] ==
            ([.meals[].timestamp] | sort | unique)) and
        ([.boosts[].timestamp] ==
            ([.boosts[].timestamp] | sort | unique))
    ' "$1" >/dev/null 2>&1
}

init_data() {
    local tmp

    if [[ ! -d "$HOME/storage/shared" ]]; then
        echo 'Stockage indisponible : lance termux-setup-storage.'
        return 1
    fi

    mkdir -p "$DATA_DIR" || return 1

    if [[ ! -e "$JSON" ]]; then
        tmp=$(mktemp "$DATA_DIR/.initial.XXXXXXXX") || return 1

        if ! printf '{"version":2,"interval_hours":12,"boost_effect_hours":6,"boost_display_hours":12,"meals":[],"boosts":[]}\n' > "$tmp"; then
            rm -f "$tmp"
            return 1
        fi

        if [[ -e "$JSON" ]]; then
            rm -f "$tmp"
        else
            mv -n "$tmp" "$JSON" || {
                rm -f "$tmp"
                return 1
            }
            rm -f "$tmp"
        fi
    fi

    if ! valid_json "$JSON"; then
        echo "ERREUR : JSON absent, invalide ou d'une ancienne version : $JSON"
        echo "Aucune donnee ecrasee. Sauvegarde eventuelle : $JSON.bak"
        return 1
    fi
}

# JSON ecrit par fichier temporaire, copie precedente dans .bak.
commit_json() {
    local tmp backup

    tmp=$(mktemp "$DATA_DIR/.new.XXXXXXXX") || return 1

    if ! jq "$@" "$JSON" > "$tmp" ||
       ! valid_json "$tmp"; then
        rm -f "$tmp"
        echo 'ERREUR : enregistrement non effectue. JSON inchange.'
        return 1
    fi

    backup=$(mktemp "$DATA_DIR/.bak.XXXXXXXX") || {
        rm -f "$tmp"
        return 1
    }

    if ! cp "$JSON" "$backup" ||
       ! mv -f "$backup" "$JSON.bak"; then
        rm -f "$tmp" "$backup"
        echo 'ERREUR : sauvegarde impossible. JSON inchange.'
        return 1
    fi

    if ! mv -f "$tmp" "$JSON"; then
        rm -f "$tmp"
        echo 'ERREUR : ecriture JSON impossible.'
        return 1
    fi
}

latest_meal() {
    jq -r '
        if (.meals | length) == 0
        then empty
        else .meals[-1].timestamp
        end
    ' "$JSON"
}

latest_boost() {
    jq -r '
        if (.boosts | length) == 0
        then empty
        else .boosts[-1].timestamp
        end
    ' "$JSON"
}

# Boost le plus recent avant l'heure proposee.
previous_boost() {
    jq -r --argjson t "$1" '
        [.boosts[] | select(.timestamp < $t) | .timestamp] |
        if length == 0 then empty else max end
    ' "$JSON"
}

# Simulation non bloquante : aucun enregistrement sans confirmation.
preview_boost() {
    local timestamp="$1" previous effect end remaining choice

    effect=$(jq -r '.boost_effect_hours' "$JSON")
    end=$((timestamp + effect * 3600))
    previous=$(previous_boost "$timestamp")

    clear 2>/dev/null || true

    echo 'Simulation BOOST'
    echo '-------------------'
    echo

    printf 'BOOST : %s\n' "$(format_time "$timestamp")"
    printf 'Fin effet BOOST estimee : %s\n' "$(format_time "$end")"
    printf 'Duree estimee : %s h\n' "$effect"

    if [[ -n "$previous" ]]; then
        remaining=$((previous + effect * 3600 - timestamp))

        if (( remaining > 0 )); then
            echo
            echo 'ATTENTION : intervalle configure non ecoule.'
            printf 'BOOST precedent : %s\n' "$(format_time "$previous")"
            printf 'Temps depuis precedent : %s\n' \
                "$(format_duration "$((timestamp - previous))")"
            printf 'Ecart restant : %s\n' \
                "$(format_duration "$remaining")"
        fi
    fi

    echo
    echo '1) Confirmer'
    echo '0) Annuler'
    echo

    read -r -p 'Choix : ' choice || return 1
    [[ "$choice" == 1 ]]
}

# Ajout manuel de repas = rattrapage, pas insertion ancienne.
check_meal_time() {
    local ts="$1" last now

    now=$(date +%s)
    last=$(latest_meal)

    if (( ts > now )); then
        echo 'Impossible : REPAS dans le futur.'
        return 1
    fi

    if [[ -n "$last" ]] && (( ts <= last )); then
        echo 'Impossible : le REPAS doit etre apres le dernier REPAS.'
        return 1
    fi
}

# Repas + Boost : un seul horodatage commun.
write_meal() {
    local ts="$1" with_boost="$2"

    if [[ "$with_boost" == true ]]; then

        if jq -e --argjson t "$ts" '
            any(.boosts[]; .timestamp == $t)
        ' "$JSON" >/dev/null; then
            echo 'Un BOOST existe deja a cette heure. REPAS non enregistre.'
            return 1
        fi

        commit_json --argjson t "$ts" '
            .meals += [
                {"timestamp":$t,"with_boost":true}
            ] |
            .boosts += [
                {"timestamp":$t,"with_meal":true}
            ] |
            .boosts |= sort_by(.timestamp)
        '

    else

        commit_json --argjson t "$ts" '
            .meals += [
                {"timestamp":$t,"with_boost":false}
            ]
        '

    fi
}

# Question Boost AVANT l'enregistrement du repas.
meal_with_choice() {
    local ts="$1" choice

    check_meal_time "$ts" || {
        pause_error
        return
    }

    clear 2>/dev/null || true

    printf 'REPAS : %s\n' "$(format_time "$ts")"
    echo
    echo '1) Avec BOOST'
    echo '2) Sans BOOST'
    echo '0) Annuler'
    echo

    read -r -p 'Choix : ' choice || return

    case "$choice" in
        1)
            if preview_boost "$ts"; then
                write_meal "$ts" true || pause_error
            fi
            ;;
        2)
            write_meal "$ts" false || pause_error
            ;;
        0|"")
            return
            ;;
        *)
            echo 'Choix invalide. Rien enregistre.'
            pause_error
            ;;
    esac
}

# Lecture de date facultative + heure obligatoire.
# Seul le timestamp est envoye sur stdout.
read_manual_timestamp() {
    local input day hour ts

    echo 'Date (JJ MM AAAA, Entree = aujourd hui)' >&2
    read -r -p 'Date : ' input || return 1

    if [[ -z "$input" ]]; then
        day=$(date +%F)
    else
        day=$(parse_day "$input") || return 1
    fi

    echo 'Heure obligatoire (HH MM)' >&2
    read -r -p 'Heure : ' input || return 1

    hour=$(parse_hour "$input") || return 1

    ts=$(date -d "$day $hour:00" +%s 2>/dev/null) || return 1

    [[ "$(date -d "@$ts" '+%F %H:%M')" == "$day $hour" ]] ||
        return 1

    (( ts <= $(date +%s) )) || return 1

    printf '%s' "$ts"
}

manual_meal() {
    local ts

    clear 2>/dev/null || true
    echo 'Ajouter un REPAS en retard'
    echo

    ts=$(read_manual_timestamp) || {
        echo 'Date/heure invalide ou future. Rien enregistre.'
        pause_error
        return
    }

    meal_with_choice "$ts"
}

# Un Boost manuel peut etre insere entre des evenements existants.
boost_at() {
    local ts="$1"

    if jq -e --argjson t "$ts" '
        any(.boosts[]; .timestamp == $t)
    ' "$JSON" >/dev/null; then
        echo 'Un BOOST existe deja a cet horaire.'
        pause_error
        return
    fi

    if preview_boost "$ts"; then
        commit_json --argjson t "$ts" '
            .boosts += [
                {"timestamp":$t,"with_meal":false}
            ] |
            .boosts |= sort_by(.timestamp)
        ' || pause_error
    fi
}

manual_boost() {
    local ts

    clear 2>/dev/null || true
    echo 'Ajouter un BOOST en retard'
    echo

    ts=$(read_manual_timestamp) || {
        echo 'Date/heure invalide ou future. Rien enregistre.'
        pause_error
        return
    }

    boost_at "$ts"
}

manual_menu() {
    local choice

    while true; do
        clear 2>/dev/null || true

        echo 'Ajout manuel'
        echo
        echo '1) REPAS en retard'
        echo '3) BOOST en retard'
        echo '0) Retour'
        echo

        read -r -p 'Choix : ' choice || return

        case "$choice" in
            1)
                manual_meal
                return
                ;;
            3)
                manual_boost
                return
                ;;
            0|"")
                return
                ;;
            *)
                echo 'Choix invalide.'
                pause_error
                ;;
        esac
    done
}

show_menu() {
    local now last boost interval effect display next diff end elapsed

    clear 2>/dev/null || true

    now=$(date +%s)
    last=$(latest_meal)
    boost=$(latest_boost)

    interval=$(jq -r '.interval_hours' "$JSON")
    effect=$(jq -r '.boost_effect_hours' "$JSON")
    display=$(jq -r '.boost_display_hours' "$JSON")

    echo 'mealtracker_android'
    echo '-------------------'

    if [[ -z "$last" ]]; then
        echo 'Dernier REPAS : Aucun'
        echo 'Temps depuis REPAS : --'
    else
        printf 'Dernier REPAS : %s\n' "$(format_time "$last")"
        printf 'Temps depuis REPAS : %s\n' \
            "$(format_duration "$((now - last))")"
    fi

    # Tout le bloc Boost disparait apres sa duree d'affichage.
    if [[ -n "$boost" ]]; then

        elapsed=$((now - boost))

        if (( elapsed >= 0 && elapsed < display * 3600 )); then
            echo

            printf 'Dernier BOOST : %s\n' \
                "$(format_time "$boost")"

            printf 'Temps depuis BOOST : %s\n' \
                "$(format_duration "$elapsed")"

            end=$((boost + effect * 3600))

            printf 'Fin effet BOOST estimee : %s\n' \
                "$(format_time "$end")"

            if (( now < end )); then
                printf 'Effet estime restant : %s\n' \
                    "$(format_duration "$((end - now))")"
            else
                echo 'Effet estime termine'
            fi
        fi
    fi

    echo
    printf 'Intervalle REPAS : %s h\n' "$interval"

    if [[ -z "$last" ]]; then
        echo 'Prochain REPAS prevu : --'
        echo 'Prochain REPAS dans : --'
    else
        next=$((last + interval * 3600))
        diff=$((next - now))

        printf 'Prochain REPAS prevu : %s\n' \
            "$(format_time "$next")"

        if (( diff >= 0 )); then
            printf 'Prochain REPAS dans : %s\n' \
                "$(format_duration "$diff")"
        else
            printf 'Delai depasse de : %s\n' \
                "$(format_duration "$((-diff))")"
        fi
    fi

    echo
    echo '1) Enregistrer un REPAS'
    echo '3) Enregistrer un BOOST'
    echo '5) Ajout manuel'
    echo '7) Historique'
    echo '8) Actualiser'
    echo '9) Setup / Update'
    echo '0) Quitter'
    echo
}

history_view() {
    local start="$1" end="$2" label="$3"
    local from to nextday raw view
    local ts priority kind assoc
    local meals=0 boosts=0 page total last answer

    from=$(date -d "$start 00:00:00" +%s) || return 1
    nextday=$(date -d "$end +1 day" +%F) || return 1
    to=$(date -d "$nextday 00:00:00" +%s) || return 1

    raw=$(mktemp) || return 1
    view=$(mktemp) || {
        rm -f "$raw"
        return 1
    }

    if ! jq -r --argjson a "$from" --argjson b "$to" '
        (
            .meals[] |
            select(.timestamp >= $a and .timestamp < $b) |
            [.timestamp,1,"MEAL",.with_boost] | @tsv
        ),
        (
            .boosts[] |
            select(.timestamp >= $a and .timestamp < $b) |
            [.timestamp,2,"BOOST",.with_meal] | @tsv
        )
    ' "$JSON" |
    sort -s -t $'\t' -k1,1n -k2,2n > "$raw"; then

        rm -f "$raw" "$view"
        echo 'Erreur de lecture historique.'
        pause_error
        return 1
    fi

    {
        echo "Historique : $label"
        echo "Du $(date -d "$start" +%d/%m/%Y) au $(date -d "$end" +%d/%m/%Y)"
        echo '--------------------------------'
    } > "$view"

    while IFS=$'\t' read -r ts priority kind assoc; do

        [[ -z "$ts" ]] && continue

        case "$kind" in
            MEAL)
                printf '%s : REPAS\n' \
                    "$(format_time "$ts")" >> "$view"
                ((meals += 1))
                ;;

            BOOST)
                if [[ "$assoc" == true ]]; then
                    printf '%s : BOOST (avec REPAS)\n' \
                        "$(format_time "$ts")" >> "$view"
                else
                    printf '%s : BOOST\n' \
                        "$(format_time "$ts")" >> "$view"
                fi

                ((boosts += 1))
                ;;
        esac
    done < "$raw"

    {
        echo '--------------------------------'
        echo "REPAS : $meals | BOOST : $boosts"
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

        echo 'Historique des REPAS et BOOST'
        echo
        echo '1) 7 derniers jours'
        echo '2) 30 derniers jours'
        echo "3) Tout l'historique"
        echo '4) Choisir une periode'
        echo '0) Retour'
        echo

        read -r -p 'Choix : ' choice || return

        today=$(date +%F)

        first=$(jq -r '
            ([.meals[].timestamp] + [.boosts[].timestamp]) |
            if length == 0 then empty else min end
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
                    echo 'La fin doit etre apres le debut.'
                    pause_error
                    continue
                fi

                history_view "$start" "$end" 'periode choisie'
                ;;

            0|"")
                return
                ;;

            *)
                echo 'Choix invalide.'
                pause_error
                ;;
        esac
    done
}

# Choix d'une duree en heures.
change_hours() {
    local field="$1" title="$2" choice hours

    while true; do
        clear 2>/dev/null || true

        printf '%s : %s h\n' "$title" \
            "$(jq -r --arg f "$field" '.[$f]' "$JSON")"

        echo
        echo '1) 6 heures'
        echo '2) 8 heures'
        echo '3) 10 heures'
        echo '4) 12 heures'
        echo '5) Autre duree en heures'
        echo '0) Retour'
        echo

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

            0|"")
                return
                ;;

            *)
                echo 'Choix invalide.'
                pause_error
                continue
                ;;
        esac

        if commit_json --arg f "$field" --argjson h "$hours" \
            '.[$f] = $h'; then
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
        echo

        printf '1) Intervalle REPAS : %s h\n' \
            "$(jq -r '.interval_hours' "$JSON")"

        printf '3) Effet BOOST estime : %s h\n' \
            "$(jq -r '.boost_effect_hours' "$JSON")"

        printf '5) Affichage BOOST : %s h\n' \
            "$(jq -r '.boost_display_hours' "$JSON")"

        echo '9) Run Setup / Update'
        echo '0) Retour'
        echo

        read -r -p 'Choix : ' choice || return

        case "$choice" in
            1)
                change_hours interval_hours 'Intervalle REPAS'
                ;;

            3)
                change_hours boost_effect_hours 'Effet BOOST estime'
                ;;

            5)
                change_hours boost_display_hours 'Affichage BOOST'
                ;;

            9)
                bash "$APP_DIR/mealtracker_setup.sh"
                ;;

            0|"")
                return
                ;;

            *)
                echo 'Choix invalide.'
                pause_error
                ;;
        esac
    done
}

main() {
    local choice

    if ! command -v jq >/dev/null 2>&1; then
        echo 'jq manquant. Lance mealtracker_setup.sh.'
        pause_error
        return 1
    fi

    init_data || {
        pause_error
        return 1
    }

    while true; do
        show_menu

        read -r -p 'Choix : ' choice || break

        case "$choice" in
            1)
                meal_with_choice "$(date +%s)"
                ;;

            3)
                boost_at "$(date +%s)"
                ;;

            5)
                manual_menu
                ;;

            7)
                history_menu
                ;;

            8)
                :
                ;;

            9)
                setup_menu
                ;;

            0|"")
                break
                ;;

            *)
                echo 'Choix invalide.'
                pause_error
                ;;
        esac
    done
}

main "$@"

