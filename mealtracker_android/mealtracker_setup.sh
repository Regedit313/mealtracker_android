
#!/data/data/com.termux/files/usr/bin/bash
# Setup non destructif pour le nouveau format Boost (version 2).
set -u

DATA_DIR="$HOME/storage/shared/mealtracker_data"
JSON="$DATA_DIR/meals.json"

finish() {
    local status="$1"
    echo
    read -r -p 'Press Enter to continue...' _ || true
    exit "$status"
}

echo 'MealTracker Boost - Setup / Update'

if [[ ! -d "$HOME/storage/shared" ]]; then
    echo 'Stockage indisponible. Lance termux-setup-storage.'
    finish 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo 'Installation de jq...'

    pkg install -y jq || {
        echo 'Echec installation jq.'
        finish 1
    }
else
    echo 'jq deja installe : OK'
fi

mkdir -p "$DATA_DIR" || {
    echo 'Erreur dossier de donnees.'
    finish 1
}

if [[ ! -e "$JSON" ]]; then
    tmp=$(mktemp "$DATA_DIR/.initial.XXXXXXXX") || finish 1

    if ! printf '{"version":2,"interval_hours":12,"boost_effect_hours":6,"boost_display_hours":12,"meals":[],"boosts":[]}\n' > "$tmp" ||
       ! mv -n "$tmp" "$JSON"; then

        rm -f "$tmp"
        echo 'Echec creation JSON.'
        finish 1
    fi

    rm -f "$tmp"

    echo 'Nouvel historique Boost initialise.'
    echo 'Repas : 12 h | Effet Boost : 6 h | Affichage Boost : 12 h'

else

    if ! jq -e '
        .version == 2 and
        (.meals | type == "array") and
        (.boosts | type == "array") and
        (.interval_hours | type == "number") and
        (.boost_effect_hours | type == "number") and
        (.boost_display_hours | type == "number")
    ' "$JSON" >/dev/null 2>&1; then

        echo 'JSON existant incompatible. Aucune modification.'
        echo 'Pour repartir de zero, sauvegarde ou supprime toi-meme l ancien JSON.'
        finish 1
    fi

    echo 'Historique et reglages Boost existants conserves.'
fi

echo "Donnees : $JSON"
echo 'Setup termine.'

finish 0

