"""Required workflow gates classify all PRs before choosing expensive CI."""
import ast
import importlib.util
from pathlib import Path
import re
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]


def evaluate(expression, values, success=True, boolean=True):
    """Evaluate only the Actions expression subset used by these gates."""
    expression = expression.removeprefix('${{').removesuffix('}}').strip()
    explicit_status = re.search(r'\b(?:cancelled|success|failure|always)\(', expression)
    if not explicit_status and not success:
        return False
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    expression = re.sub(r'!(?!=)', ' not ', expression)
    expression = re.sub(r'\b(?:github|needs|steps|matrix)\.[\w.-]+', lambda match: repr(values[match[0]]), expression)
    expression = re.sub(r"(?<!['\w])true(?!['\w])", 'True', expression)
    expression = re.sub(r"(?<!['\w])false(?!['\w])", 'False', expression)
    tree = ast.parse(expression.strip(), mode='eval')
    functions = {'cancelled': lambda: values['cancelled'], 'success': lambda: success,
                 'always': lambda: True, 'failure': lambda: not success and not values['cancelled'],
                 'startsWith': lambda text, prefix: text.startswith(prefix)}
    allowed = (ast.Expression, ast.BoolOp, ast.And, ast.Or, ast.UnaryOp, ast.Not,
               ast.Compare, ast.Eq, ast.NotEq, ast.Constant, ast.Call, ast.Name, ast.Load)
    for node in ast.walk(tree):
        if not isinstance(node, allowed):
            raise ValueError('Unknown expression shape')
        if isinstance(node, ast.Name) and node.id not in functions:
            raise ValueError('Unknown expression function')
        if isinstance(node, ast.Call) and (not isinstance(node.func, ast.Name) or node.keywords):
            raise ValueError('Unknown expression call')
    result = eval(compile(tree, '<workflow condition>', 'eval'), {'__builtins__': {}}, functions)
    return bool(result) if boolean else result


def context(run_ci='true', validate='success', ffi='success', mode='local', event='pull_request', draft=False, base='main', cancelled=False):
    return {'needs.validate_sdk_pin.outputs.run_ci': run_ci,
            'steps.changes.outputs.run_ci': run_ci,
            'needs.validate_sdk_pin.result': validate, 'needs.build_ffi.result': ffi,
            'needs.validate_sdk_pin.outputs.mode': mode, 'needs.build.result': 'success',
            'github.event_name': event, 'github.event.pull_request.draft': draft,
            'github.base_ref': base, 'cancelled': cancelled}


class RequiredWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflows = {name: yaml.safe_load((ROOT / '.github/workflows' / (name + '.yml')).read_text())
                         for name in ('pull-request', 'e2e-smoke')}

    def test_all_prs_report_before_docs_skip_and_public_triggers_stay_unchanged(self):
        for workflow in self.workflows.values():
            triggers = workflow.get('on', workflow.get(True))
            self.assertNotIn('paths-ignore', triggers['pull_request'])
            self.assertNotIn('paths', triggers['pull_request'])
            self.assertEqual(['opened', 'synchronize', 'reopened', 'ready_for_review'], triggers['pull_request']['types'])
            self.assertNotIn('push', triggers)
            self.assertEqual({'pull_request', 'workflow_dispatch'} if workflow['name'] == 'E2E Smoke Tests' else {'pull_request'}, set(triggers))

    def test_classification_is_read_only_before_pin_validation_and_exports_result(self):
        for workflow in self.workflows.values():
            gate = workflow['jobs']['validate_sdk_pin']
            self.assertEqual({'contents': 'read', 'pull-requests': 'read'}, gate.get('permissions'))
            self.assertEqual('${{ steps.changes.outputs.run_ci }}', gate['outputs']['run_ci'])
            for key in ('mode', 'pin', 'sdk_path'):
                self.assertEqual('${{ steps.companion.outputs.' + key + ' }}', gate['outputs'][key])
            steps = gate['steps']
            classify = next(step for step in steps if step.get('id') == 'changes')
            pin = next(step for step in steps if step.get('id') == 'companion')
            tests = next(step for step in steps if 'unittest' in step.get('run', ''))
            self.assertLess(steps.index(classify), steps.index(tests))
            self.assertLess(steps.index(tests), steps.index(pin))
            self.assertIn('python3 Scripts/ci/pr_change_filter.py --profile app --github-output "$GITHUB_OUTPUT"', classify['run'])
            self.assertEqual('${{ github.token }}', classify['env']['GH_TOKEN'])
            self.assertIn('test_pr_change_filter.py', tests['run'])
            self.assertFalse(evaluate(pin['if'], context(run_ci='false')))
            self.assertTrue(evaluate(pin['if'], context()))
            self.assertFalse(evaluate(pin['if'], context(), success=False))

    def test_actual_job_conditions_skip_docs_and_retain_required_failure_gates(self):
        cases = [
            # values, validation scheduled, FFI scheduled, consumer scheduled
            (context(), True, True, True),
            (context(mode='remote', ffi='skipped'), True, False, True),
            (context(run_ci='false', ffi='skipped'), True, False, False),
            (context(run_ci='', validate='failure', ffi='skipped'), True, False, False),
            (context(run_ci='false', validate='failure', ffi='skipped'), True, False, False),
            (context(validate='cancelled', ffi='skipped'), True, False, False),
            (context(ffi='failure'), True, True, False),
            (context(ffi='cancelled'), True, True, False),
            (context(draft=True, validate='skipped', ffi='skipped'), False, False, False),
            (context(draft=True, base='release/3.18.0'), True, True, True),
            (context(draft=True, base='release/3.18.0', run_ci='false', ffi='skipped'), True, False, False),
            (context(event='workflow_dispatch'), True, True, True),
            (context(cancelled=True), False, False, False),
        ]
        for name, workflow in self.workflows.items():
            jobs = workflow['jobs']
            consumer = jobs['unit_tests' if name == 'pull-request' else 'build']
            self.assertEqual(['validate_sdk_pin', 'build_ffi'], consumer['needs'])
            self.assertEqual('validate_sdk_pin', jobs['build_ffi']['needs'])
            for values, pin_want, ffi_want, consumer_want in cases:
                if name == 'pull-request' and values['github.event_name'] == 'workflow_dispatch':
                    continue
                with self.subTest(workflow=name, values=values):
                    self.assertEqual(pin_want, evaluate(jobs['validate_sdk_pin']['if'], values, success=not values['cancelled']))
                    self.assertEqual(ffi_want, evaluate(jobs['build_ffi']['if'], values, success=values['needs.validate_sdk_pin.result'] == 'success' and not values['cancelled']))
                    self.assertEqual(consumer_want, evaluate(consumer['if'], values, success=False))
        shellcheck = self.workflows['pull-request']['jobs']['shellcheck']
        self.assertNotIn('if', shellcheck)
        self.assertNotIn('needs', shellcheck)

    def test_existing_check_names_runners_and_matrix_remain_public(self):
        expected = {'pull-request': {'validate_sdk_pin', 'build_ffi', 'shellcheck', 'unit_tests'},
                    'e2e-smoke': {'validate_sdk_pin', 'build_ffi', 'build', 'e2e-ios'}}
        for name, workflow in self.workflows.items():
            self.assertEqual(expected[name], set(workflow['jobs']))
            self.assertTrue(workflow['concurrency']['cancel-in-progress'])
            for job_id, job in workflow['jobs'].items():
                runner = evaluate(job['runs-on'], context(), boolean=False) if str(job['runs-on']).startswith('${{') else job['runs-on']
                self.assertEqual('ubuntu-latest' if job_id in ('validate_sdk_pin', 'shellcheck') else 'macos-26', runner)
                self.assertEqual('e2e-ios (phase ${{ matrix.phase }})' if job_id == 'e2e-ios' else job_id, job.get('name', job_id))
        matrix = self.workflows['e2e-smoke']['jobs']['e2e-ios']
        self.assertEqual(['validate_sdk_pin', 'build'], matrix['needs'])
        self.assertEqual([1, 2], matrix['strategy']['matrix']['phase'])
        for result in ('failure', 'cancelled', 'skipped'):
            self.assertFalse(evaluate(matrix['if'], dict(context(), **{'needs.build.result': result}), success=False))

    def test_docs_expand_required_phase_contexts_after_validation(self):
        matrix = self.workflows['e2e-smoke']['jobs']['e2e-ios']
        cases = [
            # A skipped build must still report both phases for validated docs.
            (context(run_ci='false'), 'skipped', True),
            (context(run_ci='false', draft=True, base='release/3.18.0'), 'skipped', True),
            (context(), 'success', True),
            (context(mode='remote', ffi='skipped'), 'success', True),
            (context(event='workflow_dispatch'), 'success', True),
            (context(draft=True, base='release/3.18.0'), 'success', True),
            (context(draft=True), 'success', False),
            (context(draft=True, run_ci='false'), 'skipped', False),
            (context(run_ci='false', validate='failure'), 'skipped', False),
            (context(run_ci='false', validate='cancelled'), 'skipped', False),
            (context(run_ci='false', validate='skipped'), 'skipped', False),
            (context(run_ci='false', cancelled=True), 'skipped', False),
            (context(cancelled=True), 'success', False),
            (context(run_ci=''), 'success', False),
            (context(run_ci='unknown'), 'success', False),
            (context(), 'failure', False),
            (context(), 'cancelled', False),
            (context(), 'skipped', False),
            (context(validate='failure'), 'success', False),
        ]

        for values, build, want in cases:
            values = dict(values, **{'needs.build.result': build})
            with self.subTest(values=values):
                scheduled = evaluate(matrix['if'], values, success=False)
                self.assertEqual(want, scheduled)
                emitted = [matrix['name'].replace('${{ matrix.phase }}', str(phase))
                           for phase in matrix['strategy']['matrix']['phase']] if scheduled else []
                self.assertEqual(['e2e-ios (phase 1)', 'e2e-ios (phase 2)'] if want else [], emitted)
        self.assertEqual(1, sum(job.get('name', '') == matrix['name']
                                for job in self.workflows['e2e-smoke']['jobs'].values()))

        self.assertEqual(['validate_sdk_pin', 'build'], matrix['needs'])

    def test_docs_use_ubuntu_and_code_keeps_native_runner(self):
        runner = self.workflows['e2e-smoke']['jobs']['e2e-ios']['runs-on']
        self.assertEqual('ubuntu-latest', evaluate(runner, context(run_ci='false'), boolean=False) if runner.startswith('${{') else runner)
        self.assertEqual('macos-26', evaluate(runner, context(), boolean=False) if runner.startswith('${{') else runner)

    def test_docs_skip_native_steps_even_after_failure_or_cancellation(self):
        steps = self.workflows['e2e-smoke']['jobs']['e2e-ios']['steps']
        for step in steps:
            if step['name'] == 'Report docs-only E2E phase':
                continue
            for phase in (1, 2):
                for success, cancelled in ((True, False), (False, False), (False, True)):
                    values = dict(context(run_ci='false', cancelled=cancelled), **{
                        'matrix.phase': phase, 'steps.sdk-db.outputs.exists': 'true'})
                    with self.subTest(step=step['name'], phase=phase, success=success, cancelled=cancelled):
                        self.assertFalse(evaluate(step.get('if', 'true'), values, success=success))

    def test_docs_disable_every_e2e_side_effect_and_code_retains_step_status_semantics(self):
        steps = self.workflows['e2e-smoke']['jobs']['e2e-ios']['steps']
        reporter = [step for step in steps if step['name'] == 'Report docs-only E2E phase']
        self.assertEqual(1, len(reporter))
        self.assertNotIn('uses', reporter[0])
        self.assertIn('run', reporter[0])
        self.assertTrue(evaluate(reporter[0]['if'], context(run_ci='false')))
        self.assertFalse(evaluate(reporter[0]['if'], context()))
        native = [step for step in steps if step not in reporter]
        old_conditions = {
            'Restore Zcash SDK DB cache': '${{ matrix.phase == 2 }}',
            'Check for a cacheable Zcash SDK DB': '${{ always() && matrix.phase == 2 }}',
            'Save Zcash SDK DB cache': "${{ always() && matrix.phase == 2 && steps.sdk-db.outputs.exists == 'true' }}",
            'Upload test results': 'always()',
        }
        self.assertEqual([
            'Select Xcode (pinned, avoiding iOS 26.5 driver bug)',
            'Pin simulator device to the iOS 26.2 runtime',
            'Checkout smoke tests',
            'Download .app bundle',
            'Boot simulator and install app',
            'Install Maestro',
            'Install Foundry + zbar',
            'Restore Zcash SDK DB cache',
            'Run smoke tests',
            'Check for a cacheable Zcash SDK DB',
            'Save Zcash SDK DB cache',
            'Upload test results',
        ], [step['name'] for step in native])
        for phase in (1, 2):
            for success, cancelled in ((True, False), (False, False), (False, True)):
                for exists in ('true', 'false', ''):
                    values = dict(context(cancelled=cancelled), **{
                        'matrix.phase': phase, 'steps.sdk-db.outputs.exists': exists})
                    for step in native:
                        with self.subTest(step=step['name'], phase=phase, success=success, cancelled=cancelled, exists=exists):
                            docs = dict(values, **{'needs.validate_sdk_pin.outputs.run_ci': 'false'})
                            self.assertFalse(evaluate(step.get('if', 'true'), docs, success=success))
                            self.assertEqual(evaluate(old_conditions.get(step['name'], 'true'), values, success=success),
                                             evaluate(step.get('if', 'true'), values, success=success))

    def test_app_profile_keeps_case_sensitive_template_and_code_boundaries(self):
        path = ROOT / 'Scripts/ci/pr_change_filter.py'
        self.assertTrue(path.is_file(), 'missing reviewed PR classifier')
        spec = importlib.util.spec_from_file_location('app_classifier', path)
        classifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(classifier)
        for path, expected in [('.github/pull_request_template.md', False), ('docs/deep/a.md', False),
                               ('.github/PULL_REQUEST_TEMPLATE.md', True), ('AGENTS.md', True),
                               ('secant/Sources/File.swift', True), ('.sdk-pin', True),
                               ('.github/workflows/pull-request.yml', True)]:
            with self.subTest(path=path):
                self.assertEqual(expected, classifier.requires_ci([{'filename': path, 'status': 'modified'}], 'app'))

    def test_condition_evaluator_rejects_unknown_shapes(self):
        for expression in ('contains("x", "x")', 'github.event_name[0]', '1 + 2', 'True if True else False'):
            with self.assertRaises((KeyError, ValueError)):
                evaluate(expression, context())


if __name__ == '__main__':
    unittest.main()
