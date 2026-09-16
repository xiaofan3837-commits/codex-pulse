#!/usr/bin/env python3
"""Exercise the shipped executable against isolated SQLite fixtures."""
import json, os, pathlib, sqlite3, subprocess, tempfile, unittest, uuid
ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = ROOT / 'Codex Pulse.app/Contents/MacOS/CodexPulse'

class StatusTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = pathlib.Path(self.temp.name)
        self.state = sqlite3.connect(self.home / 'state_5.sqlite')
        self.state.execute('CREATE TABLE threads(id TEXT, name TEXT, title TEXT, cwd TEXT, updated_at INTEGER, archived INTEGER, thread_source TEXT, source TEXT, rollout_path TEXT)')
        self.history = sqlite3.connect(self.home / 'thread_history_1.sqlite')
        self.history.execute('CREATE TABLE thread_turns(thread_id TEXT, status TEXT, turn_id TEXT, started_at INTEGER, completed_at INTEGER, rollout_ordinal INTEGER)')
    def tearDown(self):
        self.state.close(); self.history.close(); self.temp.cleanup()
    def thread(self, id, status=None, archived=0, source='user', rollout_path=None):
        self.state.execute('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?,?)', (id, id+' title','prompt', '/project',100,archived,source,'vscode',str(rollout_path) if rollout_path is not None else None))
        if status:
            self.history.execute('INSERT INTO thread_turns VALUES(?,?,?,?,?,?)', (id,status,id+'-turn',90,None,1))
    def rollout(self, logical_id, storage_id=None):
        sessions = self.home / 'sessions' / '2026' / '09' / '16'
        sessions.mkdir(parents=True, exist_ok=True)
        suffix = logical_id if storage_id is None else logical_id + '_' + storage_id
        path = sessions / ('rollout-2026-09-16T12-18-43-' + suffix + '.jsonl')
        # Both metadata IDs remain logical IDs; the storage ID is in the filename.
        metadata = {'type': 'session_meta', 'payload': {'id': logical_id, 'session_id': logical_id}}
        path.write_text(json.dumps(metadata) + '\n')
        return path
    def turn(self, storage_id, status, turn_id='current-turn', ordinal=1):
        self.history.execute('INSERT INTO thread_turns VALUES(?,?,?,?,?,?)', (storage_id,status,turn_id,110,None,ordinal))
    def read(self):
        self.state.commit(); self.history.commit()
        env=dict(os.environ, CODEX_HOME=str(self.home))
        result=subprocess.run([str(BIN),'--diagnose'],env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        return json.loads(result.stdout)
    def test_all_statuses_and_exclusions(self):
        for id,status in [('r','inProgress'),('c','completed'),('i','interrupted'),('f','failed'),('u','newFutureState'),('n',None)]: self.thread(id,status)
        self.thread('archived','inProgress',archived=1)
        self.thread('guardian','inProgress',source='guardian_review')
        self.thread('subagent','inProgress',source='subagent')
        rows=self.read()
        self.assertEqual({r['id']:r['status'] for r in rows}, {'r':'running','c':'completed','i':'interrupted','f':'failed','u':'unknown','n':'unknown'})
        self.assertEqual(rows[0]['id'],'r')
        self.assertEqual(rows[-1]['id'],'c')
    def test_new_turn_replaces_old_completion(self):
        self.thread('a','completed')
        self.history.execute('INSERT INTO thread_turns VALUES(?,?,?,?,?,?)',('a','inProgress','second',110,None,20))
        self.assertEqual(self.read()[0]['status'],'running')
        self.history.execute("UPDATE thread_turns SET status='completed' WHERE turn_id='second'")
        self.assertEqual(self.read()[0]['status'],'completed')
    def test_migrated_running_turn_replaces_old_logical_interruption(self):
        logical_id, storage_id = str(uuid.uuid4()), str(uuid.uuid4())
        self.thread(logical_id, 'interrupted', rollout_path=self.rollout(logical_id, storage_id))
        self.history.execute('UPDATE thread_turns SET rollout_ordinal=99999 WHERE thread_id=?', (logical_id,))
        self.turn(storage_id, 'inProgress')
        row = self.read()[0]
        self.assertEqual(row['id'], logical_id)
        self.assertEqual(row['status'], 'running')
        self.assertEqual(row['turnID'], 'current-turn')
        self.assertEqual(row['started'], 110)
    def test_migrated_running_turn_transitions_to_completed(self):
        logical_id, storage_id = str(uuid.uuid4()), str(uuid.uuid4())
        self.thread(logical_id, 'interrupted', rollout_path=self.rollout(logical_id, storage_id))
        self.turn(storage_id, 'inProgress')
        self.assertEqual(self.read()[0]['status'], 'running')
        self.history.execute("UPDATE thread_turns SET status='completed', completed_at=120 WHERE turn_id='current-turn'")
        self.assertEqual(self.read()[0]['status'], 'completed')
    def test_rollover_without_turns_does_not_reuse_old_history(self):
        logical_id, old_storage_id, new_storage_id = (str(uuid.uuid4()) for _ in range(3))
        self.thread(logical_id, 'completed', rollout_path=self.rollout(logical_id, old_storage_id))
        self.turn(old_storage_id, 'inProgress')
        self.assertEqual(self.read()[0]['status'], 'running')
        new_path = self.rollout(logical_id, new_storage_id)
        self.state.execute('UPDATE threads SET rollout_path=? WHERE id=?', (str(new_path), logical_id))
        row = self.read()[0]
        self.assertEqual(row['status'], 'unknown')
        self.assertEqual(row['turnID'], '')
    def test_legacy_rollout_filename_uses_logical_history(self):
        logical_id = str(uuid.uuid4())
        self.thread(logical_id, 'inProgress', rollout_path=self.rollout(logical_id))
        self.assertEqual(self.read()[0]['status'], 'running')
    def test_missing_rollout_path_uses_legacy_history(self):
        for path in [None, '']:
            with self.subTest(path=path):
                logical_id = str(uuid.uuid4())
                self.thread(logical_id, 'inProgress', rollout_path=path)
                rows = {row['id']: row for row in self.read()}
                self.assertEqual(rows[logical_id]['status'], 'running')
    def test_missing_rollout_file_still_uses_authoritative_storage_id(self):
        logical_id, storage_id = str(uuid.uuid4()), str(uuid.uuid4())
        path = self.rollout(logical_id, storage_id)
        path.unlink()
        self.thread(logical_id, 'completed', rollout_path=path)
        self.turn(storage_id, 'inProgress')
        row = self.read()[0]
        self.assertEqual(row['status'], 'running')
        self.assertEqual(row['turnID'], 'current-turn')
    def test_malformed_rollout_suffix_does_not_reuse_logical_history(self):
        for suffix in ['not-a-uuid.jsonl', '.jsonl', str(uuid.uuid4()) + '.json']:
            with self.subTest(suffix=suffix):
                logical_id = str(uuid.uuid4())
                path = self.home / ('rollout-2026-09-16T12-18-43-' + logical_id + '_' + suffix)
                self.thread(logical_id, 'completed', rollout_path=path)
                rows = {row['id']: row for row in self.read()}
                self.assertEqual(rows[logical_id]['status'], 'unknown')
                self.assertEqual(rows[logical_id]['turnID'], '')
    def test_foreign_logical_id_in_rollout_does_not_borrow_another_task(self):
        logical_id, foreign_id, storage_id = (str(uuid.uuid4()) for _ in range(3))
        self.thread(logical_id, 'completed', rollout_path=self.rollout(foreign_id, storage_id))
        self.turn(storage_id, 'inProgress')
        row = self.read()[0]
        self.assertEqual(row['status'], 'unknown')
        self.assertEqual(row['turnID'], '')
    def test_no_database_mutations(self):
        self.thread('a','completed'); self.state.commit(); self.history.commit()
        files=['state_5.sqlite','thread_history_1.sqlite']
        before={f:(self.home/f).read_bytes() for f in files}
        self.read()
        self.assertEqual(before,{f:(self.home/f).read_bytes() for f in files})
    def test_missing_history_fails_visibly(self):
        self.history.close(); (self.home/'thread_history_1.sqlite').unlink()
        result=subprocess.run([str(BIN),'--diagnose'],env=dict(os.environ,CODEX_HOME=str(self.home)),capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('无法读取',result.stderr)
    def test_titles_are_plain_data(self):
        self.thread('x','completed')
        self.state.execute("UPDATE threads SET name=?", ('$(touch /tmp/never-execute) <script>标题</script>',))
        self.assertEqual(self.read()[0]['title'],'$(touch /tmp/never-execute) <script>标题</script>')

if __name__=='__main__': unittest.main(verbosity=2)
