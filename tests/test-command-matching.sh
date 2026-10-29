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
load normalize matches_word matches_exact_word matches_send ends_with_send \
     subtract_narration narration_update line_has_send line_has_stem \
     word_is_send all_words_send is_burst cmd_forms register_cmd word_is_cmd

# --- the few things they call out to, stubbed deterministically ---
player_speaking() { [[ "${NARRATING:-0}" == 1 ]]; }
tts_recently_said() { return 1; }   # superseded by subtraction; must stay unused

# --- configuration, as shipped ---
TRANSCRIBE_STEM=transcri; TRANSCRIBE_ALT_STEM=subscrib
SEND_STEM=send; REPEAT_TURN_STEM=repeat; REPEAT_STEM=recap
WINDOW_STEM=window; PLAY_STEM=play; PAUSE_STEM=pause
FORWARD_STEM=forward; REWIND_STEM=rewind; CANCEL_STEM=cancel
STT_WAKE_SEND_END_MAX_WORDS=20
STT_WAKE_TRANSCRIBE_WORD=transcribe
DIGEST_STEM=digest; DIAGNOSTIC_STEM=diagnos; CLEAR_STEM=text
# The form registry, exactly as the listener builds it.
declare -A CMD_FORMS=()
register_cmd transcri transcribe subscribe
register_cmd subscrib subscribe
register_cmd recap    recap
register_cmd repeat   repeat
register_cmd cancel   cancel cancelled
register_cmd send     send sent
register_cmd window   window
register_cmd pause    pause
register_cmd play     play
register_cmd forward  forward
register_cmd rewind   rewind
register_cmd digest   digest
register_cmd diagnos  diagnostic
register_cmd text     text
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
        lone)  matches_send       "$res" && got=FIRE || got=ignore ;;
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
expect FIRE   word  transcri "transcribe"
expect FIRE   word  transcri "transcribes"
expect FIRE   word  transcri "transcribed"           # whisper adds a -d to the spoken word
expect FIRE   word  transcri "subscribe"             # whisper's usual mishearing
expect FIRE   word  transcri "transcribe transcribe" # repeat-to-force burst

section "BUG-074: saying the word 'transcription' must not end your take"
# The cut-offs the user hit live, copied from stream.log:
#   08:35:28  transcribe-end trigger: 'transcription.'
#   08:35:46  transcribe-end trigger: 'by itself stopping my transcription.'
# The stem is the first 8 chars of "transcribe", so "transcri" also prefixes
# "transcription" — and the end rule is "last word matches, <=6 words". Talking
# ABOUT dictation therefore ended the dictation, which reads as "it stops by
# itself". The suite previously ASSERTED this, so it could never catch it.
reset_narration
expect ignore end   transcri "transcription"
expect ignore end   transcri "by itself stopping my transcription"
expect ignore end   transcri "I just had a whole transcription"
expect ignore end   transcri "it stopped the transcription"
expect ignore end   transcri "read me the transcript"
expect ignore end   transcri "check the transcripts"
expect ignore end   transcri "it keeps transcribing"
expect ignore word  transcri "transcription"
expect ignore word  transcri "the transcription"
expect ignore word  transcri "transcript"
# ...while the real gesture still closes the take.
expect FIRE   end   transcri "transcribe"
expect FIRE   end   transcri "okay transcribe"
expect FIRE   end   transcri "ok thats it transcribe"
# The end rule caps the phrase at 6 words (send's cap is 20, and configurable).
# Left alone here: widening it is a separate decision, not part of this bug.
expect ignore end   transcri "thats what I wanted to say transcribe"
expect FIRE   end   transcri "subscribe"

section "BUG-074: the same prefix trap in every other command"
reset_narration
expect ignore word  cancel   "cancellation"          # would have fired cancel
expect ignore word  cancel   "the cancellation fee"
expect FIRE   word  cancel   "cancel"
expect FIRE   word  cancel   "cancelled"
expect ignore word  forward  "forwarding"
expect ignore word  forward  "I am forwarding it"
expect FIRE   word  forward  "forward"
expect ignore word  recap    "recapture"
expect FIRE   word  recap    "recap"
expect ignore word  window   "windowless"
expect FIRE   word  window   "window"
expect FIRE   word  window   "windows"

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

section "matches_send: the listening-state 'send' (missed in the first pass)"
reset_narration
expect FIRE   lone send "send"
expect FIRE   lone send "uh send"
expect FIRE   lone send "send send send"                       # repeat-to-force
expect ignore lone send "the send button is broken"
expect ignore lone send "I want to send the email tomorrow"
# ...and it must work while the agent is talking, which is the whole point
narrating "the Nick Coffee message to three"
expect FIRE   lone send "Send the Nick Coffee message to three"
reset_narration
narrating "anything is set after court and before the gate sends any request"
expect ignore lone send "anything is set. After court and before the gate sends any"
reset_narration
narrating "i will send the message now"
expect FIRE   lone send "i will send the message now send"

section "BUG-076: an annotation-only line must normalize to EMPTY, not a space"
# whisper prefixes every line with a space, so " [BLANK_AUDIO]" normalized to
# " " — non-empty. Four guards test this with [[ -n ]] and all four inverted on
# silence, the normal state. mic_health said "I can hear you: 40 of the last 40
# segments had speech" while the mic delivered pure silence; the echo latch
# cleared on silence; voice.active was always fresh; one near-miss reason could
# never fire. The matchers word-split, so they were fine — which is why the
# commands kept working while every explanation of them lied.
reset_narration
norm_is_empty() {                  # the predicate all four guards actually want
    local got; got="$(normalize "$1")"
    if [[ -z "$got" ]]; then PASS=$((PASS+1)); else
        FAIL=$((FAIL+1))
        printf 'FAIL  normalize(%s) should be EMPTY, got [%s]\n' "'$1'" "$got"
    fi
}
norm_is_speech() {
    local got; got="$(normalize "$1")"
    if [[ -n "$got" ]]; then PASS=$((PASS+1)); else
        FAIL=$((FAIL+1))
        printf 'FAIL  normalize(%s) should be SPEECH, got empty\n' "'$1'"
    fi
}
norm_is_empty " [BLANK_AUDIO]"       # exactly the bytes whisper writes
norm_is_empty "[BLANK_AUDIO]"
norm_is_empty " [BLANK_AUDIO] "
norm_is_empty " (soft music)"
norm_is_empty " (birds chirping)"
norm_is_empty " (water splashing)"
norm_is_empty " [MUSIC PLAYING]"
norm_is_empty " *clears throat*"
norm_is_empty "   "
norm_is_empty ""
norm_is_speech " Transcribe."
norm_is_speech " hello there"
norm_is_speech " (door closes) Transcribe."

section "normalize: whisper's noise annotations are not speech"
reset_narration
expect ignore exact play     "[MUSIC PLAYING]"
expect FIRE   word  transcri "(dramatic music) Transcribe."
expect FIRE   word  transcri "(door closes) Transcribe."

section "BUG-075: silence must never close a take"
# The log line that gave this away, from a take that died 8s after it started:
#   16:36:56  transcribe-end trigger: '[BLANK_AUDIO]'
# whisper emits [BLANK_AUDIO] throughout silence and normalize() strips it to
# the empty string. BUG-074's form registry then matched that empty string,
# because cmd_forms() emits a LEADING and a TRAILING space, so joining the
# forms of two words ("transcribe", "subscribe") produced a double space, and
# word_is_cmd's ` $w ` test matched it when $w was "". The old prefix test
# `[[ "" == "transcri"* ]]` was false, so BUG-074's fix introduced this.
reset_narration
expect ignore end   transcri "[BLANK_AUDIO]"
expect ignore end   transcri ""
expect ignore end   transcri "[SILENCE]"
expect ignore end   transcri "(silence)"
expect ignore word  transcri "[BLANK_AUDIO]"
expect ignore send  send     "[BLANK_AUDIO]"
expect ignore lone  send     "[BLANK_AUDIO]"
expect ignore exact play     "[BLANK_AUDIO]"
# A take still closes on the real word, including through the alias whose
# registration created the double space in the first place.
expect FIRE   end   transcri "transcribe"
expect FIRE   end   transcri "subscribe"
expect FIRE   word  transcri "subscribed"

section "ordinary speech must never trigger anything"
reset_narration
for s in transcri send repeat play pause forward window cancel recap; do
    case "$s" in
        send)         expect ignore send  "$s" "lets talk about the weather today" ;;
        repeat|play|pause) expect ignore exact "$s" "lets talk about the weather today" ;;
        *)            expect ignore word  "$s" "lets talk about the weather today" ;;
    esac
done

section "the discriminating case: a 2-word residue WHILE the agent talks"
# Every other while-narrating case leaves a SINGLE word, which satisfies even
# the old `count == 1` rule — so none of them can tell the rules apart. A
# filler beside the command is what separates them, and it is how people
# actually talk: nobody says a bare "send".
reset_narration
narrating "the message to three is ready"
expect FIRE   lone  send     "uh send the message to three is ready"
reset_narration
narrating "nothing new to report"
expect FIRE   word  transcri "okay transcribe nothing new to report"
reset_narration
narrating "the last block again"
expect FIRE   exact repeat   "uh repeat the last block again"

printf '\n%s\n' "-----------------------------------------"
printf 'passed %d   failed %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
