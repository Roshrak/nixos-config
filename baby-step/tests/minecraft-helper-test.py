#!/usr/bin/env python3
"""No game launch or input: logs, target ownership and truthful failure paths."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('minecraft_helper',ROOT/'launch_mc_and_spawn.py')
mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)


class MinecraftTests(unittest.TestCase):
    def test_missing_then_created_log_is_followed(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'latest.log'; cursor=mc.LogCursor(p); self.assertEqual(cursor.read(),[])
            p.write_text('fresh event\n'); self.assertEqual(cursor.read(),['fresh event'])

    def test_old_events_ignored_partial_lines_and_rotation_followed(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'latest.log'; p.write_text('old teleport\n'); cursor=mc.LogCursor(p)
            self.assertEqual(cursor.read(),[])
            with p.open('a') as f: f.write('new par')
            self.assertEqual(cursor.read(),[])
            with p.open('a') as f: f.write('tial\n')
            self.assertEqual(cursor.read(),['new partial'])
            p.rename(Path(tmp)/'old.log'); p.write_text('rotated event\n')
            self.assertEqual(cursor.read(),['rotated event'])

    def test_generic_other_player_join_does_not_verify_our_join(self):
        cursor=Mock(); cursor.read.return_value=['Connecting to alt.crazy-fools.co.uk', '[CHAT] OtherPlayer joined the game']
        with patch.object(mc.time,'monotonic',side_effect=[0,0,0,1,3]),patch.object(mc.time,'sleep'):
            self.assertFalse(mc.wait_for_join(cursor,mc.SERVER_ADDR,2))

    def test_requested_connection_and_welcome_are_required(self):
        cursor=Mock(); cursor.read.return_value=['Connecting to alt.crazy-fools.co.uk', '[CHAT] Welcome to Crazy-Fools']
        with patch.object(mc.time,'monotonic',side_effect=[0,0,0]):
            self.assertTrue(mc.wait_for_join(cursor,mc.SERVER_ADDR,2))

    def test_browser_title_does_not_target_browser(self):
        session=mc.NiriSession({}); session.windows=Mock(return_value=[{'id':1,'app_id':'chromium','title':'Minecraft guide'}])
        self.assertIsNone(session.minecraft())

    def test_multiple_game_windows_are_refused(self):
        session=mc.NiriSession({}); session.windows=Mock(return_value=[{'id':1,'app_id':'minecraft'},{'id':2,'app_id':'Minecraft'}])
        with self.assertRaises(RuntimeError): session.minecraft()

    def test_focus_command_failure_is_not_claimed_success(self):
        session=mc.NiriSession({}); session.minecraft=Mock(return_value={'id':1,'app_id':'minecraft'})
        session.command=Mock(side_effect=RuntimeError('fixture focus failed'))
        with self.assertRaises(RuntimeError): session.focus()

    def test_unfocused_or_locked_target_prevents_input(self):
        session=mc.NiriSession({}); session.unlocked=Mock(); session.minecraft=Mock(return_value={'id':1,'is_focused':False})
        session.command=Mock()
        with self.assertRaises(RuntimeError): mc.send_spawn(session,1,Path('/fixture/uinput'))
        session.command.assert_not_called()

    def test_input_failure_propagates_without_enter_or_retry(self):
        session=Mock(spec=mc.NiriSession); session.command.side_effect=[None,RuntimeError('fixture input failure')]
        with patch.object(mc.time,'sleep'),self.assertRaises(RuntimeError):
            mc.send_spawn(session,1,Path('/fixture/uinput'))
        self.assertEqual(session.command.call_count,2)

    def test_timeout_never_types_or_claims_completion(self):
        session=Mock(); session.minecraft.return_value={'id':1}
        with patch.object(mc,'NiriSession',return_value=session),patch.object(mc,'wait_for_join',return_value=False),patch.object(mc,'send_spawn') as send,patch.object(mc.subprocess,'Popen') as launch:
            self.assertEqual(mc.main(['--log','/fixture/missing.log','--timeout','1']),1)
            send.assert_not_called(); launch.assert_not_called()

    def test_unconfirmed_teleport_is_not_success_and_not_retried(self):
        session=Mock(); session.minecraft.return_value={'id':1}; session.focus.return_value=1
        with patch.object(mc,'NiriSession',return_value=session),patch.object(mc,'wait_for_join',return_value=True),patch.object(mc,'wait_for_spawn',return_value=False),patch.object(mc,'send_spawn') as send:
            self.assertEqual(mc.main(['--log','/fixture/missing.log']),1)
            send.assert_called_once()

    def test_malformed_ipc_data_refused(self):
        session=mc.NiriSession({}); session.command=Mock(return_value=subprocess.CompletedProcess([],0,stdout=json.dumps({'unsupported':True})))
        with self.assertRaises(RuntimeError): session.windows()

    def test_environment_is_inherited_without_stale_socket_override(self):
        env={'NIRI_SOCKET':'/fixture/live.sock','DISPLAY':':42','WAYLAND_DISPLAY':'wayland-current'}
        self.assertEqual(mc.NiriSession(env).env,env)


if __name__=='__main__': unittest.main(verbosity=2)
