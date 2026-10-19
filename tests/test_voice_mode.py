from __future__ import annotations

import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "prototype"))

import agent_source  # noqa: E402
import speak_loop  # noqa: E402

_input_spec = importlib.util.spec_from_file_location(
    "input_region", ROOT / "plugins" / "stt" / "input-region.py")
input_region = importlib.util.module_from_spec(_input_spec)
assert _input_spec.loader is not None
_input_spec.loader.exec_module(input_region)


class InputRegionTests(unittest.TestCase):
    def test_codex_uses_last_prompt_and_wrapped_input(self):
        capture = """› old submitted request
  old continuation

• old answer

› the current dictated request is long enough to wrap
  and this is its continuation

  gpt-5.6-sol xhigh · ~/code/project
"""
        self.assertEqual(
            input_region.extract_input_region(capture),
            "the current dictated request is long enough to wrap and this is its continuation",
        )

    def test_codex_placeholder_is_empty(self):
        capture = """• Finished the work.

› Ask Codex to do anything

  gpt-5.6-sol xhigh · ~/code/project
"""
        self.assertEqual(input_region.extract_input_region(capture), "")

    def test_real_prompt_beginning_with_ask_codex_is_not_placeholder(self):
        capture = """› Ask Codex to fix the voice parser

  gpt-5.6-sol xhigh · ~/code/project
"""
        self.assertEqual(
            input_region.extract_input_region(capture),
            "Ask Codex to fix the voice parser",
        )

    def test_claude_composer_still_works(self):
        capture = """assistant output
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
❯ dictated text
  wraps here
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
footer
"""
        self.assertEqual(
            input_region.extract_input_region(capture), "dictated text wraps here")


class SourceSelectionTests(unittest.TestCase):
    def test_known_repl_does_not_fall_through_to_stale_other_transcript(self):
        with mock.patch.object(agent_source.CodexSource, "locate", return_value=None), \
             mock.patch.object(agent_source.ClaudeCodeSource, "locate",
                               return_value=Path("/stale/claude.jsonl")):
            selected = agent_source._source_for_cwd("/work", "codex")
        self.assertIsInstance(selected, agent_source.CodexSource)

    def test_pane_source_changes_parser_when_running_repl_changes(self):
        state = {"repl": "claude"}
        with mock.patch.object(agent_source, "_tmux", return_value="/work"), \
             mock.patch.object(agent_source, "_repl_in_pane",
                               side_effect=lambda pane: state["repl"]):
            source = agent_source.PaneSource("%1")
            self.assertEqual(source._resolve(force=True).name, "claude")
            state["repl"] = "codex"
            self.assertEqual(source._resolve(force=True).name, "codex")

    def test_codex_output_shape_is_parsed(self):
        source = agent_source.CodexSource("/work")
        obj = {
            "type": "response_item",
            "timestamp": "now",
            "payload": {
                "role": "assistant",
                "content": [{"type": "output_text", "text": "Codex answer"}],
            },
        }
        self.assertEqual([c.text for c in source.extract(obj)], ["Codex answer"])


class RewriteBackendTests(unittest.TestCase):
    def test_zero_exit_quota_banner_is_not_narration(self):
        result = subprocess.CompletedProcess(
            ["claude"], 0,
            stdout="You've hit your weekly limit · resets Sep 14 at 1am",
            stderr="",
        )
        with mock.patch.object(speak_loop.shutil, "which", return_value="/bin/claude"), \
             mock.patch.object(speak_loop.subprocess, "run", return_value=result):
            self.assertEqual(speak_loop._claude("prompt", "sonnet", 2), "")

    def test_auto_backend_follows_chunk_source(self):
        with mock.patch.dict(speak_loop.os.environ, {}, clear=False), \
             mock.patch.object(speak_loop, "_codex", return_value="Codex rewrite") as codex, \
             mock.patch.object(speak_loop, "_claude", return_value="") as claude:
            speak_loop.os.environ.pop("SPEAKLOOP_REWRITE_BACKEND", None)
            out = speak_loop._llm("prompt", "codex", "haiku", 2)
        self.assertEqual(out, "Codex rewrite")
        codex.assert_called_once()
        claude.assert_not_called()

    def test_codex_helper_is_ephemeral_and_outside_project(self):
        seen = {}

        def run(cmd, **kwargs):
            seen.update(cmd=cmd, kwargs=kwargs)
            output = cmd[cmd.index("--output-last-message") + 1]
            Path(output).write_text("A clean final narration.")
            return subprocess.CompletedProcess(cmd, 0, stdout="events", stderr="")

        with mock.patch.object(speak_loop.shutil, "which", return_value="/bin/codex"), \
             mock.patch.object(speak_loop.subprocess, "run", side_effect=run):
            out = speak_loop._codex("prompt", 2)
        self.assertEqual(out, "A clean final narration.")
        self.assertIn("--ephemeral", seen["cmd"])
        self.assertEqual(seen["kwargs"]["cwd"], speak_loop.tempfile.gettempdir())


if __name__ == "__main__":
    unittest.main()
