import json, pathlib, subprocess, unittest
BIN = pathlib.Path(__file__).resolve().parents[1] / 'Codex Pulse.app/Contents/MacOS/CodexPulse'
class UsageTests(unittest.TestCase):
    def parse(self, payload):
        return subprocess.run([str(BIN),'--parse-usage'],input=json.dumps(payload),text=True,capture_output=True)
    def test_current_bucket_wins(self):
        r=self.parse({'rateLimits':{'primary':{'usedPercent':1}},'rateLimitsByLimitId':{'codex':{'primary':{'usedPercent':61,'windowDurationMins':300,'resetsAt':1789546878},'secondary':{'usedPercent':10,'windowDurationMins':10080}}}})
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(json.loads(r.stdout)['primary']['usedPercent'],61)
        self.assertEqual(json.loads(r.stdout)['secondary']['windowDurationMins'],10080)
    def test_legacy_fallback(self):
        r=self.parse({'rateLimits':{'primary':{'usedPercent':0,'windowDurationMins':300}}})
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(json.loads(r.stdout)['primary']['usedPercent'],0)
    def test_missing_usage_is_not_zero(self):
        for payload in [{}, {'rateLimits':None}, {'rateLimits':{'primary':None,'secondary':None}}, {'rateLimitsByLimitId':{'another-model':{'primary':{'usedPercent':5}}}}]:
            with self.subTest(payload=payload): self.assertNotEqual(self.parse(payload).returncode,0)
    def test_secondary_only_preserved(self):
        r=self.parse({'rateLimits':{'secondary':{'usedPercent':10,'windowDurationMins':10080}}})
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertNotIn('primary',json.loads(r.stdout))
    def test_malformed_percent_fails(self):
        self.assertNotEqual(self.parse({'rateLimits':{'primary':{'usedPercent':'invalid'}}}).returncode,0)
if __name__ == '__main__': unittest.main(verbosity=2)
