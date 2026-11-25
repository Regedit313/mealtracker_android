
#!/data/data/com.termux/files/usr/bin/bash
# Setup non destructif : jq et creation initiale du JSON.
set -u

DATA_DIR="$HOME/storage/shared/mealtracker_data"
JSON="$DATA_DIR/meals.json"

finish() {
    local status="$1"
    echo
    read -r -p 'Press Enter to continue...' _ || true
    exit "$status"
}

echo 'MealTracker - Setup / Update'
if [[ ! -d "$HOME/storage/shared" ]]; then
    echo 'Stockage indisponible. Lance termux-setup-storage.'
    finish 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo 'Installation de jq...'
    pkg install -y jq || { echo 'Echec installation jq.'; finish 1; }
else
    echo 'jq deja installe : OK'
fi
mkdir -p "$DATA_DIR" || { echo 'Erreur dossier de donnees.'; finish 1; }
if [[ ! -e "$JSON" ]]; then
    tmp=$(mktemp "$DATA_DIR/.initial.XXXXXXXX") || finish 1
    if ! printf '{"version":1,"interval_hours":12,"meals":[]}\n' > "$tmp" ||
       ! mv -n "$tmp" "$JSON"; then
        rm -f "$tmp"
        echo 'Echec creation JSON.'
        finish 1
    fi
    rm -f "$tmp"
    echo 'Nouvel historique cree (intervalle initial : 12 h).'
else
    if ! jq -e '
        .version == 1 and
        (.meals | type == "array") and
        (.interval_hours | type == "number")
    ' "$JSON" >/dev/null 2>&1; then
        echo 'JSON existant invalide : aucune modification.'
        finish 1
    fi
    echo 'Historique et intervalle existants conserves.'
fi
echo "Donnees : $JSON"
echo 'Setup termine.'
finish 0

