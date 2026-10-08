#!/usr/bin/env bash
# Regression suite for the wake listener's command matching.
#
# Every case here is a bug that actually happened, with the line whisper really
# produced. The matchers were rewritten six times over two weeks because each
# fix was checked by a throwaway script and nothing stopped the next change from
# undoing it — the "first word or within the last two" rule fixed commands
# during narration and simultaneously made 'on forward request' fire `forward`.
#
# Run: bash tests/test-command-matching.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SRC=plugins/stt/wake-listener.sh

fn() { sed -n "/^$1() {/,/^}$/p" "$SRC"; }
load() { local f; for f in "$@"; do eval "$(fn "$f")" || { echo "could not load $f"; exit 1; }; done; }

# --- the real implementations under test ---
load normalize matches_word matches_exact_word ends_with_send \
     subtract_narration narration_update line_has_send line_has_stem \
     word_is_send all_words_send is_burst

# --- the few things they call out to, stubbed deterministically ---
player_speaking() { [[ "${NARRATING:-0}" == 1 ]]; }
tts_recently_said() { return 1; }   # superseded by subtraction; must stay unused

# --- configuration, as shipped ---
TRANSCRIBE_STEM=transcri; TRANSCRIBE_ALT_STEM=subscrib
SEND_STEM=send; REPEAT_TURN_STEM=repeat; REPEAT_STEM=recap
WINDOW_STEM=window; PLAY_STEM=play; PAUSE_STEM=pause
FORWARD_STEM=forward; REWIND_STEM=rewind; CANCEL_STEM=cancel
STT_WAKE_SEND_END_MAX_WORDS=20
STT_WAKE_NARRATION_WINDOW=12
SEND_VERB_BEFORE=" to will would can could should shall must may might please cant wont dont doesnt didnt "
SECONDS=100

PASS=0; FAIL=0
reset_narration() { NARR_TEXT=(); NARR_AT=(); NARR_LAST=""; NARRATING=0; }
narrating() {                      # the agent is speaking this text right now
    NARR_TEXT+=("$(normalize "$1")"); NARR_AT+=("$SECONDS"); NARRATING=1
}
expect() {                         # expect FIRE|ignore <matcher> <stem> <heard line>
    local want="$1" kind="$2" stem="$3" heard="$4" got res
    res="$(subtract_narration "$(normalize "$heard")")"
    case "$kind" in
        word)  matches_word       "$res" "$stem" && got=FIRE || got=ignore ;;
        exact) matches_exact_word  "$res" "$stem" && got=FIRE || got=ignore ;;
        end)   matches_word       "$res" "$stem" end && got=FIRE || got=ignore ;;
        send)  ends_with_send     "$res" "$heard" && got=FIRE || got=ignore ;;
        *) echo "unknown matcher $kind"; exit 2 ;;
    esac
    if [[ "$got" == "$want" ]]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        printf 'FAIL  want=%-6s got=%-6s %s(%s)\n      heard   = %s\n      residue = [%s]\n' \
            "$want" "$got" "$kind" "$stem" "$heard" "$res"
    fi
}
section() { printf '\n%s\n' "$1"; }

# =============================================================================
section "BUG-053/055/066: whole word, not a prefix"
reset_narration
expect FIRE   exact repeat   "repeat"
expect FIRE   exact repeat   "repeats"
expect FIRE   exact repeat   "please repeat"
expect ignore exact repeat   "adjudicated repeatedly"          # fired a replay mid-sentence
expect ignore exact repeat   "it repeated the query"
expect FIRE   exact play     "play"
expect FIRE   exact play     "play play play"                  # repeat-to-force burst
expect ignore exact play     "playing"                         # resumed playback at 19:58
expect ignore exact play     "playback paused"
expect ignore exact play     "the player stopped"
expect FIRE   exact pause    "pause"
expect ignore exact pause    "paused"
expect ignore exact pause    "pausing now"
# transcribe KEEPS prefix matching on purpose: "transcription" should fire it
expect FIRE   word  transcri "transcribe"
expect FIRE   word  transcri "transcription"

section "BUG-066: a take closes on a trailing 'send', whatever whisper punctuates"
reset_narration
expect FIRE   send send "Send."
expect FIRE   send send "can you work on those things? Send."
expect FIRE   send send "can you work on those things send"    # same intent, no comma
expect FIRE   send send "lets do that send."
expect FIRE   send send "ok thats the plan send"
expect FIRE   send send "send send send"
expect FIRE   send send "uh send"
expect FIRE   send send "so what I want you to do is go look at the thing and come back and tell me. Send."
expect ignore send send "tell me what you want me to send"     # verb, not command
expect ignore send send "I think you should send"
expect ignore send send "see if the agent will send"
expect ignore send send "the send button is broken"
expect ignore send send "I want to send the email tomorrow"

section "BUG-067: your command must land while the agent is talking"
reset_narration
narrating "Nothing new to report. My question still stands."
expect FIRE   word  transcri "- Transcribe. - Nothing new to report. My question still stands."
reset_narration
narrating "the Nick Coffee message to three"
expect FIRE   exact send     "Send the Nick Coffee message to three"
reset_narration
narrating "turn will see your pending proposals from the last day"
expect FIRE   exact send     "turn will see your pending proposals from the last day. Send."

section "BUG-069: the agent's own voice must not fire commands"
reset_narration
narrating "The planter has finished. The plan is on forward request."
expect ignore word  forward  "The planter has finished. The plan is on forward request, 22.58."
reset_narration
narrating "anything is set after court and before the gate sends any request"
expect ignore exact send     "anything is set. After court and before the gate sends any"
reset_narration
narrating "web search and page reading files and sending"
expect ignore exact send     "web search and page reading, files and sending. No"
reset_narration
narrating "now you are playing the next file"
expect ignore exact play     "Now you're playing."

section "BUG-069: when BOTH said it, your copy survives"
reset_narration
narrating "i will send the message now"
expect FIRE   exact send     "i will send the message now send"
reset_narration
narrating "the transcribed output is ready"
expect FIRE   word  transcri "transcribe the transcribed output is ready"

section "normalize: whisper's noise annotations are not speech"
reset_narration
expect ignore exact play     "[MUSIC PLAYING]"
expect FIRE   word  transcri "(dramatic music) Transcribe."
expect FIRE   word  transcri "(door closes) Transcribe."

section "ordinary speech must never trigger anything"
reset_narration
for s in transcri send repeat play pause forward window cancel recap; do
    case "$s" in
        send)         expect ignore send  "$s" "lets talk about the weather today" ;;
        repeat|play|pause) expect ignore exact "$s" "lets talk about the weather today" ;;
        *)            expect ignore word  "$s" "lets talk about the weather today" ;;
    esac
done

printf '\n%s\n' "-----------------------------------------"
printf 'passed %d   failed %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
