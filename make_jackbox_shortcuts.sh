#!/usr/bin/env bash
# =============================================================================
# make_jackbox_shortcuts.sh
#
# Generates, for every game of every Jackbox Party Pack:
#   - a small .sh launcher that starts just that one game
#   - a .desktop entry with the game's icon (from the icons folder)
#
# Launch methods:
#   1) Steam  -> steam "steam://run/<APPID>//-launchTo games/<G>/<G>.swf
#                            -jbg.config isBundle=false"
#
#   2) Heroic (replaces the old Epic option) ->
#        native:  heroic "heroic://launch/<GAME_ID>?args=-launchTo%20games/<G>/<G>.swf%20-jbg.config%20isBundle=false" --no-gui
#        flatpak: flatpak run com.heroicgameslauncher.hgl --no-gui "heroic://launch/<GAME_ID>?args=..."
#      Heroic game ids are LOCAL (per machine); they are read from
#        native : ~/.config/heroic/store_cache/legendary_install_info.json
#        flatpak: ~/.var/app/com.heroicgameslauncher.hgl/config/heroic/store_cache/legendary_install_info.json
#      Titles in that file are matched against the known pack names, so we can
#      also tell which packs you actually have in Heroic.
#
#   3) Native -> cd <packdir> && ./Launcher.sh -launchTo games/<G>/<G>.swf
#                              -jbg.config isBundle=false
#      Native mode never scans your whole disk. You either type each pack path
#      yourself, or point the script at ONE folder whose DIRECT subfolders look
#      like jpp*/ or "The Jackbox Party Pack 7"/ etc.
#
# Scope: you can generate shortcuts for ALL games, only the INSTALLED ones
# (Steam libraries are checked for appmanifest_<appid>.acf; Heroic titles come
# from its cache), or hand-pick packs from a list.
#
# Extras: you can append custom launch arguments to every generated command,
# and choose how to treat the three games that exist twice (The Jackbox Party
# Starter ships updated versions of Quiplash 3 (JPP7), Tee K.O. (JPP3) and
# Trivia Murder Party 2 (JPP6)): keep both versions, JPS only, or originals
# only.
#
# Steam app-ids were taken from the Jackbox Utility community metadata
# (github.com/JackboxUtility/JackboxUtility) and verified against the local
# gameManifest.json files. (Note: jpp5/gameManifest.json in some distributions
# wrongly contains the Naughty Pack id 2652000; the real JPP5 appid is 774461.)
#
# Generated .sh scripts do NOT use "exec" (plain invocation, cwd normalized),
# because exec broke launches on some setups. The deep-link URLs (steam://...,
# heroic://...) are passed UNQUOTED on purpose too: quoting them triggers the
# same launch failure. They contain no shell metacharacters (spaces are
# %-encoded), so an unquoted call is safe.
# =============================================================================
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ICONS_DIR="${JACKBOX_ICONS_DIR:-$SCRIPT_DIR/icons}"
OUT_DIR_DEFAULT="$SCRIPT_DIR/jackbox-shortcuts"
APP_DIR="$HOME/.local/share/applications"

MODE=""            # steam | heroic | native
SCOPE=""           # all | auto | manual
OUT_DIR=""
INSTALL_MENU="n"
JPS_MODE="both"    # both | jps | orig (who gets shortcuts for the 3 shared games)
EXTRA_ARGS=""      # extra launch arguments appended to every command
HEROIC_VARIANT=""  # native | flatpak
HEROIC_CONFIG=""
GENERATED=0
SKIPPED=0
UNIQ_TITLE=""
ANSWER=""
SELECTED=()        # pids to generate (steam/heroic)
NATIVE_ORDER=()    # pids to generate (native)
STEAM_LIBS=()
SELECT_ITEMS=()
PICKED=""
PICKED_ALL=0
PICKED_NONE=0
declare -A TITLE_USED
declare -A NATIVE_DIR      # pid -> absolute pack folder
declare -A HEROIC_BY_TITLE # normalized title -> "appid|installed(yes/no)"

# -----------------------------------------------------------------------------
# Pack table: "id|Title|steam_appid"
# -----------------------------------------------------------------------------
PACKS=(
  "jpp1|The Jackbox Party Pack|331670"
  "jpp2|The Jackbox Party Pack 2|397460"
  "jpp3|The Jackbox Party Pack 3|434170"
  "jpp4|The Jackbox Party Pack 4|610180"
  "jpp5|The Jackbox Party Pack 5|774461"
  "jpp6|The Jackbox Party Pack 6|1005300"
  "jpp7|The Jackbox Party Pack 7|1211630"
  "jpp8|The Jackbox Party Pack 8|1552350"
  "jpp9|The Jackbox Party Pack 9|1850960"
  "jpp10|The Jackbox Party Pack 10|2216830"
  "jpp11|The Jackbox Party Pack 11|3364070"
  "jps|The Jackbox Party Starter|1755580"
  "jnp|The Jackbox Naughty Pack|2652000"
)

# Standalone titles (single-game apps): "id|Title|steam_appid"
STANDALONES=(
  "quip|Quiplash|351510"
  "quip2int|Quiplash 2 InterLASHional|1111940"
  "df2|Drawful 2|442070"
  "fbxl|Fibbage XL (Standalone)|448080"
  "jss|The Jackbox Survey Scramble|2948640"
  "uyw|Use Your Words|521350"
  "wtd|What The Dub?!|1495860"
  "rttg|RiffTrax: The Game|1707870"
  "pppts|Paper Pirates|1234220"
  "ppqz|Papa's Quiz|1484730"
)
STANDALONE_IDS="quip quip2int df2 fbxl jss uyw wtd rttg pppts ppqz"

ALL_IDS=(jpp1 jpp2 jpp3 jpp4 jpp5 jpp6 jpp7 jpp8 jpp9 jpp10 jpp11 jps jnp \
         quip quip2int df2 fbxl jss uyw wtd rttg pppts ppqz)

# Games per pack: "Display Name|internal name" (internal name = folder/swf used
# by the -launchTo argument, as used by the Windows shortcuts / Jackbox Utility)
declare -A GAMES
GAMES[jpp1]="You Don't Know Jack 2015|YDKJ2015
Drawful|Drawful
Word Spud|WordSpud
Lie Swatter|LieSwatterParty
Fibbage XL|FibbageXL"
GAMES[jpp2]="Fibbage 2|Fibbage2
Earwax|Earwax
Bidiots|Auction
Quiplash XL|QuiplashXL
Bomb Corp.|BombInterns"
GAMES[jpp3]="Quiplash 2|Quiplash2
Trivia Murder Party|triviadeath
Guesspionage|PollPosition
Fakin' It!|FakinIt
Tee K.O.|AwShirt"
GAMES[jpp4]="Fibbage 3|Fibbage3
Survive the Internet|SurviveTheInternet
Monster Seeking Monster|MonsterMingle
Bracketeering|Bracketeering
Civic Doodle|Overdrawn"
GAMES[jpp5]="You Don't Know Jack: Full Stream|YDKJ2018
Split the Room|SplitTheRoom
Mad Verse City|RapBattle
Zeeple Dome|SlingShoot
Patently Stupid|PatentlyStupid"
GAMES[jpp6]="Trivia Murder Party 2|TriviaDeath2
Role Models|RoleModels
Joke Boat|Jokeboat
Dictionarium|Ridictionary
Push the Button|PushTheButton"
GAMES[jpp7]="Quiplash 3|Quiplash3
The Devils & The Details|Everyday
Champ'd Up|WorldChampions
Talking Points|JackboxTalks
Blather 'Round|BlankyBlank"
GAMES[jpp8]="Drawful Animate|DrawfulAnimate
The Wheel of Enormous Proportions|TheWheel
Job Job|JobGame
The Poll Mine|SurveyBomb
Weapons Drawn|MurderDetectives"
GAMES[jpp9]="Fibbage 4|Fibbage4
Roomerang|MakeFriends
Junktopia|AntiqueGame
Nonsensory|RangeGame
Quixort|Lineup"
GAMES[jpp10]="Tee K.O. 2|AwShirt2
Timejinx|TimeTrivia
FixyText|RiskyText
Dodo Re Mi|NopusOpus
Hypnotorious|Strangers"
GAMES[jpp11]="Doominate|YouRuinedIt
Hear Say|MicGame
Cookie Haus|CookiesGame
Suspectives|DirtyDetectives
Legends of Trivia|TriviaRPG"
GAMES[jps]="Quiplash 3|Quiplash3
Tee K.O.|AwShirt
Trivia Murder Party 2|triviadeath2"
GAMES[jnp]="Fakin' It All Night Long|FakinIt2
Dirty Drawful|Drawful3
Let Me Finish|CAPTCHA"

# Folder names used to match DIRECT subfolders in native scan mode
declare -A STANDALONE_PATTERNS
STANDALONE_PATTERNS[quip]="quipplash"
STANDALONE_PATTERNS[quip2int]="quipplash 2 interlashional"
STANDALONE_PATTERNS[df2]="drawful 2"
STANDALONE_PATTERNS[fbxl]="fibbage xl standalone|fibbage xl"
STANDALONE_PATTERNS[jss]="the jackbox survey scramble|jackbox survey scramble"
STANDALONE_PATTERNS[uyw]="use your words"
STANDALONE_PATTERNS[wtd]="what the dub"
STANDALONE_PATTERNS[rttg]="rifftrax the game|rifftrax"
STANDALONE_PATTERNS[pppts]="paper pirates"
STANDALONE_PATTERNS[ppqz]="papas quiz"

# -----------------------------------------------------------------------------
# Small helpers
# -----------------------------------------------------------------------------
log()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Lowercase, strip punctuation, collapse spaces (used for name matching)
norm() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d "\"'!?.,;:()[]-" \
    | sed 's/ and / \& /g; s/  */ /g; s/^ //; s/ $//'
}

prettify() {  # AwShirt2 -> Aw Shirt 2 (best effort, unknown folders only)
  printf '%s' "$1" | sed 's/\([a-z0-9]\)\([A-Z]\)/\1 \2/g; s/  */ /g'
}

slugify() {  # "Blather 'Round" -> blather-round (file-name safe)
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g; s/^-\+//; s/-\+$//'
}

abspath() {  # best-effort absolute path
  local p
  p="$(cd -- "$1" 2>/dev/null && pwd -P)" || p="$1"
  printf '%s' "$p"
}

is_standalone() {  # $1 = pid
  case " $STANDALONE_IDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

pack_title() {  # $1 = pid
  local p
  for p in "${PACKS[@]}"; do
    IFS='|' read -r a b _ <<<"$p"
    [ "$a" = "$1" ] && { printf '%s' "$b"; return 0; }
  done
  for p in "${STANDALONES[@]}"; do
    IFS='|' read -r a b _ <<<"$p"
    [ "$a" = "$1" ] && { printf '%s' "$b"; return 0; }
  done
  printf '%s' "$1"
}

steam_id_of() {  # $1 = pid
  local p
  for p in "${PACKS[@]}" "${STANDALONES[@]}"; do
    IFS='|' read -r a b c <<<"$p"
    [ "$a" = "$1" ] && { printf '%s' "$c"; return 0; }
  done
}

pack_label() {  # short label used when two packs share a game name
  case "$1" in
    jpp*)  printf 'JPP%s' "${1#jpp}" ;;
    jps)   printf 'Starter' ;;
    jnp)   printf 'Naughty Pack' ;;
    *)     printf 'Standalone' ;;
  esac
}

urlencode() {  # minimal percent-encoding for deep-link arguments
  printf '%s' "$1" | sed 's/%/%25/g; s/ /%20/g; s/"/%22/g; s/#/%23/g; s/&/%26/g; s/?/%3F/g; s/\$/%24/g; s/`/%60/g'
}

# The Party Starter ships updated re-skins of three games that also live in
# the regular packs. JPS_MODE decides which of the two versions gets shortcuts.
jps_game_allowed() {  # $1=pid  $2=internal game name
  case "$1/$2" in
    jps/Quiplash3|jps/AwShirt|jps/triviadeath2)
      [ "$JPS_MODE" = "orig" ] && return 1 ;;
    jpp7/Quiplash3|jpp3/AwShirt|jpp6/TriviaDeath2)
      [ "$JPS_MODE" = "jps" ] && return 1 ;;
  esac
  return 0
}

patterns_for() {  # $1 = pid -> '|'-separated folder-name patterns
  local n
  case "$1" in
    jpp1) printf 'jpp1|tjpp1|the jackbox party pack' ;;
    jpp*) n="${1#jpp}"; printf 'jpp%s|tjpp%s|the jackbox party pack %s' "$n" "$n" "$n" ;;
    jps)  printf 'jps|tjps|the jackbox party starter|jackbox party starter' ;;
    jnp)  printf 'jnp|tjnp|the jackbox naughty pack|jackbox naughty pack|naughty pack' ;;
    *)    printf '%s' "${STANDALONE_PATTERNS[$1]:-}" ;;
  esac
}

# Ask for the icon file of a game title; echoes absolute path or "".
find_icon() {  # $1=title  $2=pid  $3=local pack dir (may be empty)
  local title="$1" pid="$2" packdir="${3:-}" cand f iname gname
  [ -d "$ICONS_DIR" ] || { printf ''; return 0; }
  # Party Starter ships re-skins of older games -> prefer the [Starter] icons
  if [ "$pid" = "jps" ]; then
    cand="$ICONS_DIR/$title [Starter].png"
    [ -f "$cand" ] && { printf '%s' "$cand"; return 0; }
  fi
  cand="$ICONS_DIR/$title.png"
  [ -f "$cand" ] && { printf '%s' "$cand"; return 0; }
  gname="$(norm "$title")"
  [ -z "$gname" ] && { printf ''; return 0; }
  # exact normalized match anywhere under the icons folder (up to depth 3)
  while IFS= read -r -d '' f; do
    iname="$(norm "$(basename "${f%.png}")")"
    [ "$iname" = "$gname" ] && { printf '%s' "$f"; return 0; }
  done < <(find "$ICONS_DIR" -maxdepth 3 -type f -name '*.png' -print0 2>/dev/null)
  # prefix fallback ("Civic Doodle" -> "Civic Doodle ALT.png")
  while IFS= read -r -d '' f; do
    iname="$(norm "$(basename "${f%.png}")")"
    case "$iname" in "$gname "*) printf '%s' "$f"; return 0 ;; esac
  done < <(find "$ICONS_DIR" -maxdepth 3 -type f -name '*.png' -print0 2>/dev/null)
  # fallback: the pack's own icon (native mode)
  if [ -n "$packdir" ]; then
    for cand in "$packdir/GameIcon.png" "$packdir/"*.png; do
      [ -f "$cand" ] && { printf '%s' "$cand"; return 0; }
    done
  fi
  printf ''
}

# Prompt helper. Set JACKBOX_STDIN=1 to read answers from stdin (automation).
ask() {  # $1=prompt -> sets $ANSWER
  printf '%s' "$1"
  ANSWER=""
  local r
  if [ -t 0 ] || [ -n "${JACKBOX_STDIN:-}" ]; then
    if read -r r; then ANSWER="$r"; fi
  elif { read -r r </dev/tty; } 2>/dev/null; then
    ANSWER="$r"
  else
    if read -r r; then ANSWER="$r"; fi
  fi
}

# Numbered multi-select. Prints $SELECT_ITEMS, reads an answer like "1,3-5",
# "all"/Enter or "s". Sets PICKED (space-separated indices), PICKED_ALL, PICKED_NONE.
pick_indices() {  # $1=prompt
  local i=1 x re_num='^[0-9]+$' re_rng='^[0-9]+-[0-9]+$'
  for x in ${SELECT_ITEMS[@]+"${SELECT_ITEMS[@]}"}; do
    printf '  %2d) %s\n' "$i" "$x"
    i=$((i+1))
  done
  while true; do
    ask "$1"
    local a="${ANSWER:-}"
    case "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" in
      ""|a|all|y|yes) PICKED=""; PICKED_ALL=1; PICKED_NONE=0; return 0 ;;
      s|none|n|no)    PICKED=""; PICKED_ALL=0; PICKED_NONE=1; return 0 ;;
      *)
        local picks="" ok=1 tok lo hi j
        local -a toks=()
        IFS=',' read -ra toks <<<"$a"
        for tok in ${toks[@]+"${toks[@]}"}; do
          tok="$(printf '%s' "$tok" | tr -d ' ')"
          if [[ "$tok" =~ $re_num ]]; then lo=$tok; hi=$tok;
          elif [[ "$tok" =~ $re_rng ]]; then lo="${tok%-*}"; hi="${tok#*-}";
          else ok=0; break; fi
          for ((j=lo; j<=hi; j++)); do
            if [ "$j" -ge 1 ] && [ "$j" -le "${#SELECT_ITEMS[@]}" ]; then
              picks="$picks$j "
            fi
          done
        done
        if [ "$ok" = 1 ] && [ -n "$picks" ]; then
          PICKED="$picks"; PICKED_ALL=0; PICKED_NONE=0; return 0
        fi
        warn "Enter numbers like 1,3-5, 'a' for all, 's' for none."
        ;;
    esac
  done
}

idx_in_picked() {  # $1 = index
  case " $PICKED " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Dedupe display names that exist in more than one pack (e.g. "Tee K.O." in
# JPP3 and in the Party Starter). Must be called from the parent shell (no $()).
uniq_title() {  # $1=title  $2=short pack label -> sets $UNIQ_TITLE
  if [ -n "${TITLE_USED[$1]+x}" ]; then
    UNIQ_TITLE="$1 ($2)"
  else
    UNIQ_TITLE="$1"
  fi
  TITLE_USED[$1]=1
}

# -----------------------------------------------------------------------------
# Scanning a local pack folder (native mode)
# -----------------------------------------------------------------------------
scan_game_folder() {  # $1 = <pack>/games/<GameDir> -> "folder|swf_stem" or ""
  local d="$1" base f stem best size sz
  base="$(basename "$d")"
  # 1) a swf named exactly like the folder (case-insensitive)
  for f in "$d"/*.swf; do
    [ -f "$f" ] || continue
    stem="$(basename "${f%.swf}")"
    if [ "$(norm "$stem")" = "$(norm "$base")" ]; then
      printf '%s|%s' "$base" "$stem"; return 0
    fi
  done
  # 2) biggest swf that is not engine/menu clutter
  best=""; size=0
  for f in "$d"/*.swf; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
      [Pp]latform.swf|[Pp]ause*.swf|[Mm]anager*.swf|[Pp]icker*.swf|[Gg]ame[Pp]icker.swf|[Ll]oader*.swf|TJPPLoader.swf) continue ;;
    esac
    sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    if [ "$sz" -gt "$size" ]; then size="$sz"; best="$f"; fi
  done
  [ -n "$best" ] && printf '%s|%s' "$base" "$(basename "${best%.swf}")"
  return 0
}

scan_pack() {  # $1 = pack dir -> lines "Folder|swf"
  local packdir="$1" gamesdir="$1/games" sub pair stem key
  [ -d "$gamesdir" ] || return 0
  local -A seen_exact=() seen_any=()
  while IFS= read -r -d '' sub; do
    case "$(norm "$(basename "$sub")")" in picker) continue ;; esac
    pair="$(scan_game_folder "$sub")"
    [ -z "$pair" ] && continue
    stem="${pair#*|}"
    key="$(norm "$stem")"
    if [ "$key" = "$(norm "${pair%%|*}")" ]; then
      seen_exact["$key"]="$pair"   # folder name matches swf name -> preferred
      seen_any["$key"]="$pair"
    elif [ -z "${seen_any[$key]+x}" ]; then
      seen_any["$key"]="$pair"
    fi
  done < <(find "$gamesdir" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null | sort -z)
  {
    for pair in ${seen_exact[@]+"${seen_exact[@]}"}; do printf '%s\n' "$pair"; done
    for pair in ${seen_any[@]+"${seen_any[@]}"}; do
      key="$(norm "${pair#*|}")"
      [ -n "${seen_exact[$key]+x}" ] || printf '%s\n' "$pair"
    done
  } | sort -u
}

# Map a scanned folder to the canonical table entry.
# Sets REPLY_TITLE / REPLY_INTERNAL.
match_game() {  # $1=pid  $2=scanned folder  $3=scanned swf stem
  local pid="$1" folder="$2" swf="$3" line gtitle gint
  REPLY_TITLE=""; REPLY_INTERNAL=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    gtitle="${line%%|*}"; gint="${line#*|}"
    if [ "$(norm "$folder")" = "$(norm "$gint")" ] || [ "$(norm "$swf")" = "$(norm "$gint")" ]; then
      REPLY_TITLE="$gtitle"; REPLY_INTERNAL="$gint"; return 0
    fi
  done <<<"${GAMES[$pid]:-}"
  REPLY_TITLE="$(prettify "$folder")"; REPLY_INTERNAL="$swf"
}

# -----------------------------------------------------------------------------
# Generated launch commands: plain calls, normalized cwd, NO exec and NO
# quotes around the deep-link URL (quoted URLs break the launch).
# -----------------------------------------------------------------------------
launch_body_steam() {  # $1=appid  $2=game folder ("" -> plain run)  $3=swf stem
  local uri="steam://run/$1//"
  [ -n "$2" ] && uri="$uri-launchTo games/$2/$3.swf -jbg.config isBundle=false"
  [ -n "$EXTRA_ARGS" ] && uri="$uri $EXTRA_ARGS"
  # Deliberately unquoted below: passing the URL as one quoted argv entry
  # makes Steam fail to launch (same symptom as the old exec bug).
  printf 'cd "${HOME:-/}" 2>/dev/null || true\nif command -v steam >/dev/null 2>&1; then\n  steam %s\nelse\n  xdg-open %s\nfi' "$uri" "$uri"
}

launch_body_heroic() {  # $1=heroic game id  $2=game folder ("" -> plain launch)  $3=swf stem
  local url="heroic://launch/$1" extra=""
  [ -n "$EXTRA_ARGS" ] && extra="%20$(urlencode "$EXTRA_ARGS")"
  if [ -n "$2" ]; then
    url="$url?args=-launchTo%20games/$2/$3.swf%20-jbg.config%20isBundle=false$extra"
  elif [ -n "$extra" ]; then
    url="$url?args=${extra#%20}"
  fi
  # Unquoted on purpose, like the Steam body: the URL has no shell
  # metacharacters (spaces are %20-encoded).
  if [ "$HEROIC_VARIANT" = "flatpak" ]; then
    printf 'cd "${HOME:-/}" 2>/dev/null || true\nflatpak run com.heroicgameslauncher.hgl --no-gui %s' "$url"
  else
    printf 'cd "${HOME:-/}" 2>/dev/null || true\nheroic %s --no-gui' "$url"
  fi
}

launch_body_native() {  # $1=pack dir  $2=command to run inside it
  local cmd="$2"
  [ -n "$EXTRA_ARGS" ] && cmd="$cmd $EXTRA_ARGS"
  # Only the cd target keeps its quotes (pack folders may contain spaces);
  # the launcher command and its arguments stay unquoted.
  printf 'cd "%s" || exit 1\n%s' "$1" "$cmd"
}

# Write the .sh launcher and the .desktop file.
gen_entry() {  # $1=game title  $2=pid  $3=pack title  $4=icon src ("" ok)  $5=shell body
  local title="$1" pid="$2" pack="$3" icon_src="$4" body="$5"
  local base name sh_path desk_path icon_dest="" esc
  uniq_title "$title" "$(pack_label "$pid")"
  name="$UNIQ_TITLE"
  base="jackbox-$pid-$(slugify "$title")"
  sh_path="$OUT_DIR/$base.sh"
  desk_path="$OUT_DIR/$base.desktop"

  {
    printf '#!/usr/bin/env bash\n'
    printf '# Auto-generated by make_jackbox_shortcuts script — %s (%s)\n' "$title" "$pack"
    printf '%s\n' "$body"
  } > "$sh_path"
  chmod +x "$sh_path"

  if [ -n "$icon_src" ] && [ -f "$icon_src" ]; then
    mkdir -p "$OUT_DIR/icons"
    icon_dest="$OUT_DIR/icons/$base.png"
    cp -f "$icon_src" "$icon_dest"
  fi

  esc="${sh_path//\\/\\\\}"; esc="${esc//\"/\\\"}"
  {
    printf '[Desktop Entry]\n'
    printf 'Type=Application\n'
    printf 'Name=%s\n' "$name"
    printf 'Comment=%s\n' "$pack"
    printf 'Exec=/bin/bash "%s"\n' "$esc"
    [ -n "$icon_dest" ] && printf 'Icon=%s\n' "$icon_dest"
    printf 'Terminal=false\n'
    printf 'Categories=Game;\n'
    printf 'StartupNotify=true\n'
  } > "$desk_path"

  GENERATED=$((GENERATED+1))
}

# -----------------------------------------------------------------------------
# Steam: detect installed packs via appmanifest_*.acf in the Steam libraries
# -----------------------------------------------------------------------------
discover_steam_libs() {
  local roots=(
    "$HOME/.steam/steam"
    "$HOME/.steam/root"
    "$HOME/.steam/debian-installation"
    "$HOME/.local/share/Steam"
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
    "$HOME/snap/steam/common/.local/share/Steam"
  )
  local r vdf p
  local -a found=()
  local -A seen=()
  for r in "${roots[@]}"; do
    vdf="$r/steamapps/libraryfolders.vdf"
    [ -f "$vdf" ] || continue
    [ -n "${seen[$r]+x}" ] || { seen[$r]=1; found+=("$r"); }
    while IFS= read -r p; do
      p="${p//\\\\//}"     # unescape vdf backslashes, just in case
      [ -d "$p" ] || continue
      [ -n "${seen[$p]+x}" ] || { seen[$p]=1; found+=("$p"); }
    done < <(sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)".*$/\1/p' "$vdf")
  done
  STEAM_LIBS=(${found[@]+"${found[@]}"})
}

steam_installed() {  # $1 = steam appid
  local l
  for l in ${STEAM_LIBS[@]+"${STEAM_LIBS[@]}"}; do
    [ -f "$l/steamapps/appmanifest_$1.acf" ] && return 0
  done
  return 1
}

# -----------------------------------------------------------------------------
# Heroic: variant detection + game ids from legendary_install_info.json
# -----------------------------------------------------------------------------
heroic_detect_variant() {
  local n=0 f=0
  case "${JACKBOX_HEROIC_VARIANT:-}" in
    native|flatpak) HEROIC_VARIANT="$JACKBOX_HEROIC_VARIANT"; return 0 ;;
  esac
  command -v heroic >/dev/null 2>&1 && n=1
  if command -v flatpak >/dev/null 2>&1 \
     && flatpak info com.heroicgameslauncher.hgl >/dev/null 2>&1; then
    f=1
  fi
  if [ "$n" = 1 ] && [ "$f" = 0 ]; then HEROIC_VARIANT="native"; return 0; fi
  if [ "$f" = 1 ] && [ "$n" = 0 ]; then HEROIC_VARIANT="flatpak"; return 0; fi
  log "How is Heroic installed on this machine?"
  log "  1) Native (the 'heroic' command)"
  log "  2) Flatpak (com.heroicgameslauncher.hgl)"
  ask "Choose 1/2 [1]: "
  case "${ANSWER:-1}" in
    2) HEROIC_VARIANT="flatpak" ;;
    *) HEROIC_VARIANT="native" ;;
  esac
}

heroic_find_config() {
  local native="$HOME/.config/heroic/store_cache/legendary_install_info.json"
  local flat="$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic/store_cache/legendary_install_info.json"
  if [ "$HEROIC_VARIANT" = "flatpak" ]; then
    if [ -f "$flat" ]; then HEROIC_CONFIG="$flat"; return 0; fi
    [ -f "$native" ] && { warn "flatpak Heroic config not found, using the native one: $native"; HEROIC_CONFIG="$native"; return 0; }
  else
    if [ -f "$native" ]; then HEROIC_CONFIG="$native"; return 0; fi
    [ -f "$flat" ] && { warn "native Heroic config not found, using the flatpak one: $flat"; HEROIC_CONFIG="$flat"; return 0; }
  fi
  HEROIC_CONFIG=""
}

heroic_load() {
  command -v python3 >/dev/null 2>&1 \
    || die "python3 is required to read Heroic's legendary_install_info.json"
  local out app title inst n=0
  out="$(python3 - "$HEROIC_CONFIG" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    sys.exit(f"cannot parse {sys.argv[1]}: {e}")
for key, val in data.items():
    if key == "__timestamp" or not isinstance(val, dict):
        continue
    game = val.get("game") or {}
    app = game.get("app_name") or key
    title = game.get("title") or key
    inst = "yes" if val.get("install") else "no"
    print(f"{app}\t{title}\t{inst}")
PY
)" || die "failed to read $HEROIC_CONFIG"
  while IFS=$'\t' read -r app title inst; do
    [ -z "$app" ] && continue
    HEROIC_BY_TITLE["$(norm "$title")"]="$app|$inst"
    n=$((n+1))
  done <<<"$out"
  log "Loaded $n title(s) from the Heroic cache."
}

resolve_heroic_id() {  # $1 = pack title -> sets HEROIC_ID / HEROIC_INST
  HEROIC_ID=""; HEROIC_INST=""
  local key e alt
  key="$(norm "$1")"
  e="${HEROIC_BY_TITLE[$key]:-}"
  if [ -z "$e" ]; then
    alt="$(norm "${1#The }")"   # Epic sometimes drops the leading "The"
    [ "$alt" != "$key" ] && e="${HEROIC_BY_TITLE[$alt]:-}"
  fi
  if [ -n "$e" ]; then
    HEROIC_ID="${e%%|*}"
    HEROIC_INST="${e#*|}"
  fi
}

# -----------------------------------------------------------------------------
# Scope selection (steam / heroic)
# -----------------------------------------------------------------------------
select_manual_online() {  # $1 = steam|heroic
  local pid i=1 appid
  SELECT_ITEMS=()
  for pid in "${ALL_IDS[@]}"; do
    appid="$(steam_id_of "$pid")"
    [ -z "$appid" ] && continue
    if [ "$1" = "heroic" ]; then
      resolve_heroic_id "$(pack_title "$pid")"
      [ -z "$HEROIC_ID" ] && continue
      SELECT_ITEMS+=("$(pack_title "$pid")")
    else
      SELECT_ITEMS+=("$(pack_title "$pid")  [steam: $appid]")
    fi
  done
  log ""
  log "Which packs/games should get shortcuts?"
  pick_indices "Enter numbers (e.g. 1,3-5), 'a' = all [Enter=all]: "
  SELECTED=()
  i=1
  for pid in "${ALL_IDS[@]}"; do
    appid="$(steam_id_of "$pid")"
    [ -z "$appid" ] && continue
    if [ "$1" = "heroic" ]; then
      resolve_heroic_id "$(pack_title "$pid")"
      [ -z "$HEROIC_ID" ] && continue
    fi
    if [ "$PICKED_ALL" = 1 ] || idx_in_picked "$i"; then
      SELECTED+=("$pid")
    fi
    i=$((i+1))
  done
}

setup_steam() {
  local pid appid n=0
  discover_steam_libs
  if [ "${#STEAM_LIBS[@]}" -gt 0 ]; then
    log "Found ${#STEAM_LIBS[@]} Steam library folder(s)."
  else
    warn "No Steam library folders found (tried standard locations)."
  fi
  log ""
  log "Which games should get shortcuts?"
  log "  1) All of them"
  if [ "${#STEAM_LIBS[@]}" -gt 0 ]; then
    log "  2) Only packs detected as installed in Steam (recommended)"
  fi
  log "  3) Let me pick from a list"
  ask "Choose 1/2/3 [2]: "
  SCOPE="${ANSWER:-2}"
  case "$SCOPE" in
    3) select_manual_online steam ;;
    2)
      if [ "${#STEAM_LIBS[@]}" -eq 0 ]; then
        warn "Nothing to check - falling back to manual selection."
        select_manual_online steam
        return 0
      fi
      log ""
      log "Checking Steam libraries for installed packs:"
      SELECTED=()
      for pid in "${ALL_IDS[@]}"; do
        appid="$(steam_id_of "$pid")"
        [ -z "$appid" ] && continue
        if steam_installed "$appid"; then
          log "  [x] $(pack_title "$pid")"
          SELECTED+=("$pid"); n=$((n+1))
        else
          log "  [ ] $(pack_title "$pid")"
        fi
      done
      if [ "$n" -eq 0 ]; then
        warn "No installed packs detected (maybe they are non-Steam shortcuts?)."
        select_manual_online steam
      fi
      ;;
    *) SELECTED=("${ALL_IDS[@]}") ;;
  esac
}

setup_heroic() {
  local pid title n=0
  heroic_detect_variant
  heroic_find_config
  if [ -n "$HEROIC_CONFIG" ]; then
    heroic_load
  else
    warn "Heroic's legendary_install_info.json was not found."
    warn "Looked in ~/.config/heroic/store_cache/ and the flatpak equivalent."
    warn "Without it, ids must be pasted by hand (or run Heroic once and retry)."
  fi
  log ""
  log "Which games should get shortcuts?"
  log "  1) All of them (asks for missing Heroic ids)"
  if [ -n "$HEROIC_CONFIG" ]; then
    log "  2) Only titles found in Heroic's library (recommended)"
  fi
  log "  3) Let me pick from a list"
  ask "Choose 1/2/3 [2]: "
  SCOPE="${ANSWER:-2}"
  case "$SCOPE" in
    1) SELECTED=("${ALL_IDS[@]}") ;;
    3) select_manual_online heroic ;;
    *)
      if [ -z "$HEROIC_CONFIG" ] || [ "${#HEROIC_BY_TITLE[@]}" -eq 0 ]; then
        die "No Heroic library data available - cannot filter by availability."
      fi
      log ""
      log "Titles found in Heroic:"
      SELECTED=()
      for pid in "${ALL_IDS[@]}"; do
        title="$(pack_title "$pid")"
        resolve_heroic_id "$title"
        [ -z "$HEROIC_ID" ] && continue
        if [ "$HEROIC_INST" = "yes" ]; then
          log "  [x] $title (installed)"
        else
          log "  [x] $title (owned, not installed)"
        fi
        SELECTED+=("$pid"); n=$((n+1))
      done
      if [ "$n" -eq 0 ]; then
        die "None of the known Jackbox titles were found in the Heroic cache ($HEROIC_CONFIG)."
      fi
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Native mode: explicit paths only - manual input or scan ONE folder
# -----------------------------------------------------------------------------
ask_scan_base() {
  SCAN_BASE=""
  while true; do
    ask "Folder to scan (only its direct subfolders are checked): "
    if [ -n "$ANSWER" ] && [ -d "$ANSWER" ]; then
      SCAN_BASE="$(abspath "$ANSWER")"
      return 0
    fi
    warn "'$ANSWER' is not a folder - try again"
  done
}

ask_pack_path() {  # $1 = pid -> sets NATIVE_DIR[$pid] ("" = skip)
  local pid="$1" title need answer
  title="$(pack_title "$pid")"
  if is_standalone "$pid"; then need="no"; else need="yes"; fi
  while true; do
    ask "Path to '$title' (Enter = skip this one): "
    answer="$ANSWER"
    if [ -z "$answer" ]; then NATIVE_DIR[$pid]=""; return 0; fi
    if [ ! -d "$answer" ]; then
      warn "'$answer' is not a folder - try again"; continue
    fi
    if [ "$need" = "yes" ] && [ ! -d "$answer/games" ]; then
      warn "'$answer' has no games/ subfolder - not a pack folder"; continue
    fi
    NATIVE_DIR[$pid]="$(abspath "$answer")"
    return 0
  done
}

setup_native() {
  local base sub pid pat dname found total=0 unmatched=0 i
  log ""
  log "How should I find your pack folders?"
  log "  1) I will enter the path for each pack myself"
  log "  2) Scan one folder I choose (checks only DIRECT subfolders named like"
  log "     jpp7/, TJPP3/ or 'The Jackbox Party Pack 7')"
  ask "Choose 1/2 [1]: "
  case "${ANSWER:-1}" in 2) ask_scan_base; base="$SCAN_BASE" ;; *) base="" ;; esac

  if [ -n "$base" ]; then
    log ""
    log "Scanning '$base' ..."
    while IFS= read -r -d '' sub; do
      dname="$(norm "$(basename "$sub")")"
      found=""
      for pid in "${ALL_IDS[@]}"; do
        local -a pats=()
        IFS='|' read -ra pats <<<"$(patterns_for "$pid")"
        for pat in ${pats[@]+"${pats[@]}"}; do
          if [ "$dname" = "$(norm "$pat")" ]; then found=1; break; fi
        done
        [ -n "$found" ] && break
      done
      if [ -z "$found" ]; then
        unmatched=$((unmatched+1))
        continue
      fi
      if is_standalone "$pid" || [ -d "$sub/games" ]; then
        NATIVE_DIR[$pid]="$(abspath "$sub")"
      else
        warn "'$(basename "$sub")' looks like $(pack_title "$pid") but has no games/ folder - ignored"
      fi
    done < <(find "$base" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null | sort -z)

    SELECT_ITEMS=()
    for pid in "${ALL_IDS[@]}"; do
      [ -n "${NATIVE_DIR[$pid]:-}" ] && SELECT_ITEMS+=("$(pack_title "$pid")  ->  ${NATIVE_DIR[$pid]}")
    done
    if [ "${#SELECT_ITEMS[@]}" -eq 0 ]; then
      die "No pack folders recognized in '$base'. Expected direct subfolders like jpp7/ or 'The Jackbox Party Pack 7'."
    fi
    [ "$unmatched" -gt 0 ] && log "($unmatched other subfolder(s) ignored)"
    log ""
    log "Found packs:"
    pick_indices "Generate for which packs? [Enter=all]: "
    if [ "$PICKED_NONE" = 1 ] || { [ "$PICKED_ALL" = 0 ] && [ -z "$PICKED" ]; }; then
      die "Nothing selected - nothing to generate."
    fi
    i=1
    NATIVE_ORDER=()
    for pid in "${ALL_IDS[@]}"; do
      [ -n "${NATIVE_DIR[$pid]:-}" ] || continue
      if [ "$PICKED_ALL" = 1 ] || idx_in_picked "$i"; then
        NATIVE_ORDER+=("$pid")
      fi
      i=$((i+1))
    done
  else
    log ""
    log "Which packs/games do you want to set up?"
    SELECT_ITEMS=()
    for pid in "${ALL_IDS[@]}"; do
      SELECT_ITEMS+=("$(pack_title "$pid")")
    done
    pick_indices "Enter numbers (e.g. 1,3-5), 'a' = all [Enter=all]: "
    if [ "$PICKED_NONE" = 1 ] || { [ "$PICKED_ALL" = 0 ] && [ -z "$PICKED" ]; }; then
      die "Nothing selected - nothing to generate."
    fi
    i=1
    NATIVE_ORDER=()
    for pid in "${ALL_IDS[@]}"; do
      if [ "$PICKED_ALL" = 1 ] || idx_in_picked "$i"; then
        NATIVE_ORDER+=("$pid")
      fi
      i=$((i+1))
    done
    for pid in "${NATIVE_ORDER[@]}"; do
      ask_pack_path "$pid"
    done
    local kept=()
    for pid in "${NATIVE_ORDER[@]}"; do
      [ -n "${NATIVE_DIR[$pid]:-}" ] && kept+=("$pid")
    done
    NATIVE_ORDER=(${kept[@]+"${kept[@]}"})
    if [ "${#NATIVE_ORDER[@]}" -eq 0 ]; then
      die "No paths given - nothing to generate."
    fi
  fi
}

# -----------------------------------------------------------------------------
# Native generation
# -----------------------------------------------------------------------------
do_native_pack() {  # $1 = pid (path in NATIVE_DIR)
  local pid="$1" title dir launcher f scanned filtered="" count chosen pair folder swf gtitle body icon
  title="$(pack_title "$pid")"
  dir="${NATIVE_DIR[$pid]:-}"
  [ -z "$dir" ] && return 0
  launcher="$dir/Launcher.sh"
  if [ ! -f "$launcher" ]; then
    launcher=""
    for f in "$dir"/*.sh; do
      [ -f "$f" ] && { launcher="$f"; break; }
    done
  fi
  if [ -z "$launcher" ]; then
    warn "$title: no Launcher.sh (or any *.sh) in '$dir' - skipped"
    SKIPPED=$((SKIPPED+1)); return 0
  fi
  launcher="./$(basename "$launcher")"

  scanned="$(scan_pack "$dir")"
  if [ -z "$scanned" ]; then
    warn "$title: no game folders found under $dir/games - skipped"
    SKIPPED=$((SKIPPED+1)); return 0
  fi
  # Apply the JPS/originals filter (matches canonical internal names)
  while IFS= read -r pair; do
    [ -z "$pair" ] && continue
    match_game "$pid" "${pair%%|*}" "${pair#*|}"
    if jps_game_allowed "$pid" "$REPLY_INTERNAL"; then
      filtered="$filtered$pair"$'\n'
    fi
  done <<<"$scanned"
  filtered="${filtered%$'\n'}"
  scanned="$filtered"
  if [ -z "$scanned" ]; then
    warn "$title: all games skipped by the JPS/originals setting ($JPS_MODE)"
    SKIPPED=$((SKIPPED+1)); return 0
  fi
  count="$(printf '%s\n' "$scanned" | grep -c .)"
  chosen="$scanned"
  if [ "$count" -gt 1 ]; then
    ask "Create shortcuts for ALL games in $title ($count found)? [Y/n]: "
    case "${ANSWER:-Y}" in
      n|N|no|No)
        # Yes/no per game instead of a number-range picker.
        # NB: copy the list into an array first - inside a herestring loop,
        # ask()'s read would consume the list instead of the user's answers.
        local -a pairs=()
        while IFS= read -r pair; do
          [ -z "$pair" ] && continue
          pairs+=("$pair")
        done <<<"$scanned"
        chosen=""
        for pair in ${pairs[@]+"${pairs[@]}"}; do
          match_game "$pid" "${pair%%|*}" "${pair#*|}"
          ask "  Shortcut for '$REPLY_TITLE' (games/${pair%%|*})? [Y/n]: "
          case "${ANSWER:-Y}" in
            n|N|no|No) log "    -> $REPLY_TITLE: skipped" ;;
            *) chosen="$chosen$pair"$'\n' ;;
          esac
        done
        if [ -z "$chosen" ]; then
          log "  -> $title: no games selected, skipped"
          return 0
        fi
        ;;
    esac
  fi

  log ""
  log "== $title ($dir)"
  while IFS= read -r pair; do
    [ -z "$pair" ] && continue
    folder="${pair%%|*}"; swf="${pair#*|}"
    match_game "$pid" "$folder" "$swf"
    gtitle="$REPLY_TITLE"
    icon="$(find_icon "$gtitle" "$pid" "$dir")"
    body="$(launch_body_native "$dir" "$launcher -launchTo games/$folder/$swf.swf -jbg.config isBundle=false")"
    gen_entry "$gtitle" "$pid" "$title" "$icon" "$body"
  done <<<"$chosen"
}

do_native_standalone() {  # $1 = pid (path in NATIVE_DIR)
  local pid="$1" title dir entry f body icon
  title="$(pack_title "$pid")"
  dir="${NATIVE_DIR[$pid]:-}"
  [ -z "$dir" ] && return 0
  dir="$(abspath "$dir")"
  entry=""
  [ -f "$dir/Launcher.sh" ] && entry="./Launcher.sh"
  if [ -z "$entry" ] && [ -f "$dir/AppRun" ]; then entry="./AppRun"; fi
  if [ -z "$entry" ]; then
    for f in "$dir"/*.x86_64 "$dir"/*.sh; do
      [ -f "$f" ] && { entry="./$(basename "$f")"; break; }
    done
  fi
  if [ -z "$entry" ]; then
    warn "$title: no launcher (Launcher.sh/AppRun/*.x86_64) in '$dir' - skipped"
    SKIPPED=$((SKIPPED+1)); return 0
  fi
  log ""
  log "== $title ($dir)"
  icon="$(find_icon "$title" "$pid" "$dir")"
  body="$(launch_body_native "$dir" "$entry")"
  gen_entry "$title" "$pid" "$title" "$icon" "$body"
}

generate_native() {
  local pid
  for pid in ${NATIVE_ORDER[@]+"${NATIVE_ORDER[@]}"}; do
    if is_standalone "$pid"; then
      do_native_standalone "$pid"
    else
      do_native_pack "$pid"
    fi
  done
}

# -----------------------------------------------------------------------------
# Steam / Heroic generation
# -----------------------------------------------------------------------------
generate_online() {
  local pid title appid line gtitle gint body icon
  for pid in ${SELECTED[@]+"${SELECTED[@]}"}; do
    title="$(pack_title "$pid")"
    if [ "$MODE" = "steam" ]; then
      appid="$(steam_id_of "$pid")"
      if [ -z "$appid" ]; then
        warn "$title: no Steam appid known - skipped"
        SKIPPED=$((SKIPPED+1)); continue
      fi
      log ""
      log "== $title (Steam appid $appid)"
    else
      resolve_heroic_id "$title"
      if [ -z "$HEROIC_ID" ]; then
        ask "  Heroic game id for '$title' not found in its cache - paste it from legendary_install_info.json (Enter = skip): "
        HEROIC_ID="$ANSWER"
      fi
      if [ -z "$HEROIC_ID" ]; then
        warn "$title: no Heroic id - skipped"
        SKIPPED=$((SKIPPED+1)); continue
      fi
      log ""
      log "== $title (Heroic id $HEROIC_ID)"
      appid="$HEROIC_ID"
    fi

    if is_standalone "$pid"; then
      icon="$(find_icon "$title" "$pid" "")"
      if [ "$MODE" = "steam" ]; then
        body="$(launch_body_steam "$appid" "" "")"
      else
        body="$(launch_body_heroic "$appid" "" "")"
      fi
      gen_entry "$title" "$pid" "$title" "$icon" "$body"
    else
      local made=0
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        gtitle="${line%%|*}"; gint="${line#*|}"
        if ! jps_game_allowed "$pid" "$gint"; then
          log "  - $gtitle: skipped (JPS/originals setting: $JPS_MODE)"
          continue
        fi
        icon="$(find_icon "$gtitle" "$pid" "")"
        if [ "$MODE" = "steam" ]; then
          body="$(launch_body_steam "$appid" "$gint" "$gint")"
        else
          body="$(launch_body_heroic "$appid" "$gint" "$gint")"
        fi
        gen_entry "$gtitle" "$pid" "$title" "$icon" "$body"
        made=$((made+1))
      done <<<"${GAMES[$pid]:-}"
      if [ "$made" -eq 0 ]; then
        warn "$title: nothing left to generate for this pack (JPS handling: $JPS_MODE)"
        SKIPPED=$((SKIPPED+1))
      fi
    fi
  done
}

# -----------------------------------------------------------------------------
# Simple prompts
# -----------------------------------------------------------------------------
ask_method() {
  log "How do you launch your Jackbox packs?"
  log "  1) Steam"
  log "  2) Heroic (Epic Games library; native or flatpak)"
  log "  3) Native (pack folders on disk)"
  ask "Choose 1/2/3 [1]: "
  case "${ANSWER:-1}" in
    2) MODE="heroic" ;;
    3) MODE="native" ;;
    *) MODE="steam" ;;
  esac
}

ask_jps_mode() {
  log "The Jackbox Party Starter contains updated versions of three games that"
  log "also ship inside the regular packs:"
  log "  Quiplash 3 (JPP7), Tee K.O. (JPP3), Trivia Murder Party 2 (JPP6)"
  log "Which versions should get shortcuts?"
  log "  1) Both the JPS and the original pack versions"
  log "  2) Only the JPS versions (the packs will skip these three)"
  log "  3) Only the original pack versions (the JPS games will be skipped)"
  ask "Choose 1/2/3 [1]: "
  case "${ANSWER:-1}" in
    2) JPS_MODE="jps" ;;
    3) JPS_MODE="orig" ;;
    *) JPS_MODE="both" ;;
  esac
}

ask_extra_args() {
  ask "Extra launch arguments to append to every command (Enter = none): "
  EXTRA_ARGS="${ANSWER:-}"
  [ -n "$EXTRA_ARGS" ] && log "Extra launch arguments: $EXTRA_ARGS"
}

ask_out_dir() {
  ask "Output directory [$OUT_DIR_DEFAULT]: "
  OUT_DIR="${ANSWER:-$OUT_DIR_DEFAULT}"
  mkdir -p "$OUT_DIR" || die "cannot create $OUT_DIR"
  OUT_DIR="$(abspath "$OUT_DIR")"   # after mkdir, so a new dir resolves too
}

ask_install() {
  ask "Install .desktop files into $APP_DIR? [Y/n]: "
  case "${ANSWER:-Y}" in
    n|N|no|No) INSTALL_MENU="n" ;;
    *)         INSTALL_MENU="y" ;;
  esac
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
log "==============================================="
log " Jackbox per-game shortcut generator (Linux)   "
log "==============================================="
log ""

ask_method
ask_jps_mode
case "$MODE" in
  steam)  setup_steam ;;
  heroic) setup_heroic ;;
  native) setup_native ;;
esac

if [ "$MODE" != "native" ] && [ "${#SELECTED[@]}" -eq 0 ]; then
  die "Nothing selected - nothing to generate."
fi

log ""
ask_extra_args
ask_out_dir
ask_install
mkdir -p "$OUT_DIR/icons"
log ""

case "$MODE" in
  steam|heroic) generate_online ;;
  native)       generate_native ;;
esac

if [ "$INSTALL_MENU" = "y" ]; then
  mkdir -p "$APP_DIR"
  find "$OUT_DIR" -maxdepth 1 -name '*.desktop' -exec cp -f {} "$APP_DIR/" \;
  command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$APP_DIR" >/dev/null 2>&1
  log ""
  log "Installed .desktop files to $APP_DIR"
fi

log ""
log "Done. Generated $GENERATED shortcut(s) in: $OUT_DIR"
[ "$SKIPPED" -gt 0 ] && log "Skipped entries: $SKIPPED (see warnings above)"
[ -n "$EXTRA_ARGS" ] && log "Extra launch arguments appended: $EXTRA_ARGS"
log "Icons were copied to: $OUT_DIR/icons"
log ""
case "$MODE" in
  steam)
    log "Note: the .sh files call Steam with unquoted steam://run/... URLs -"
    log "Steam starts each single game directly. No exec, no quotes."
    ;;
  heroic)
    if [ "$HEROIC_VARIANT" = "flatpak" ]; then
      log "Note: the .sh files run 'flatpak run com.heroicgameslauncher.hgl --no-gui'"
      log "with unquoted heroic://launch/... deep links (args are %-encoded)."
    else
      log "Note: the .sh files call the 'heroic' command with heroic://launch/..."
      log "deep links and --no-gui."
    fi
    [ -n "$HEROIC_CONFIG" ] && log "Heroic ids came from: $HEROIC_CONFIG"
    ;;
  native)
    log "Note: the .sh files cd into the pack folder and run its own launcher -"
    log "no Steam, Epic or Heroic needed."
    ;;
esac
