
#!/data/data/com.termux/files/usr/bin/bash
# Setup non destructif pour REPAS, BOOST et NUTRI (version 3).
set -u

DATA_DIR="$HOME/storage/shared/mealtracker_data"
JSON="$DATA_DIR/meals.json"

finish() {
    local status="$1"
    echo
    read -r -p 'Press Enter to continue...' _ || true
    exit "$status"
}

echo 'MealTracker BOOST - Setup / Update'

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

    if ! printf '{"version":3,"interval_hours":12,"boost_effect_hours":6,"boost_display_hours":12,"meals":[],"boosts":[],"nutris":[]}\n' > "$tmp" ||
       ! mv -n "$tmp" "$JSON"; then

        rm -f "$tmp"
        echo 'Echec creation JSON.'
        finish 1
    fi

    rm -f "$tmp"

    echo 'Nouvel historique REPAS, BOOST et NUTRI initialise.'
    echo 'REPAS : 12 h | Effet BOOST : 6 h | Affichage BOOST : 12 h'

else

    if ! jq -e '
        .version == 3 and
        (.interval_hours |
            type == "number" and . == floor and . >= 1 and . <= 720) and
        (.boost_effect_hours |
            type == "number" and . == floor and . >= 1 and . <= 720) and
        (.boost_display_hours |
            type == "number" and . == floor and . >= 1 and . <= 720) and
        (.meals | type == "array") and
        (.boosts | type == "array") and
        (.nutris | type == "array") and
        (all(.meals[];
            (.timestamp | type == "number" and . == floor) and
            (.with_boost | type == "boolean") and
            (.with_nutri | type == "boolean")
        )) and
        (all(.boosts[];
            (.timestamp | type == "number" and . == floor) and
            (.with_meal | type == "boolean")
        )) and
        (all(.nutris[];
            (.timestamp | type == "number" and . == floor) and
            (.with_meal == true)
        )) and
        ([.meals[].timestamp] ==
            ([.meals[].timestamp] | sort | unique)) and
        ([.boosts[].timestamp] ==
            ([.boosts[].timestamp] | sort | unique)) and
        ([.nutris[].timestamp] ==
            ([.nutris[].timestamp] | sort | unique))
    ' "$JSON" >/dev/null 2>&1; then

        echo 'JSON existant incompatible avec la version 3.'
        echo 'Aucune modification effectuee.'
        echo 'Pour repartir de zero, sauvegarde ou supprime toi-meme l ancien JSON.'
        finish 1
    fi

    echo 'Historique REPAS, BOOST, NUTRI et reglages existants conserves.'
fi

echo "Donnees : $JSON"
echo 'Setup termine.'

finish 0

