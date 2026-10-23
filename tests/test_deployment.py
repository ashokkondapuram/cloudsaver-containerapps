import copy
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import configuration as cfg
import deploy


def sample():
    return json.loads((ROOT / 'examples/production.json').read_text())


def accepted():
    c = sample()
    c['subscriptionId'] = '11111111-1111-4111-8111-111111111111'
    c['entra'].update(tenantId=c['subscriptionId'], portalClientId='22222222-2222-4222-8222-222222222222',
                      audience='identity-api', apiScope='api://identity-api/access_as_user')
    c['images'] = {k: v.replace('0' * 64, 'a' * 64) for k, v in c['images'].items()}
    c['application'] = {'sourceRevision': 'a' * 40, 'acceptanceRecord': 'staging validation record fixture'}
    return c


class ConfigurationTests(unittest.TestCase):
    def test_example_contract_and_apply_placeholder_gate(self):
        cfg.validate(sample())
        with self.assertRaises(cfg.ConfigError):
            cfg.require_real_values(sample())

    def test_accepted_config(self):
        c = accepted()
        cfg.validate(c)
        cfg.require_real_values(c)
        cfg.require_application_acceptance(c)

    def test_inline_secret_and_structural_override_rejected(self):
        for key in ['CLOUDSAVER_DATABASE_URL', 'CLOUDSAVER_WEBHOOK_PRIMARY', 'CLOUDSAVER_GITHUB_APP_PRIVATE_KEY',
                    'CLOUDSAVER_KEY_VERIFIER', 'PLATFORM_PORTAL_AUTH']:
            with self.subTest(key=key):
                c = sample(); c['backendConfig'][key] = 'sensitive-fixture-value'
                with self.assertRaises(cfg.ConfigError) as error:
                    cfg.validate(c)
                self.assertNotIn('sensitive-fixture-value', str(error.exception))

    def test_feature_combinations_fail(self):
        for name in ['scheduledScans', 'interactiveJobs', 'delivery', 'automatedAlerts']:
            with self.subTest(name=name):
                c = sample();c['features'][name] = True
                with self.assertRaises(cfg.ConfigError): cfg.validate(c)

    def test_all_workers_valid(self):
        c = sample();c['workers'] = {k: True for k in c['workers']}
        c['features'] = {k: True for k in c['features']}
        cfg.validate(c)

    def test_secret_aliasing_rejected(self):
        c = sample();c['secretNames']['cloudMigrationUrl'] = c['secretNames']['cloudDatabaseUrl']
        with self.assertRaises(cfg.ConfigError):cfg.validate(c)

    def test_extra_secret_and_collision_guards(self):
        c = sample();binding = {'workload': 'scanner', 'appSecretName': 'gitops-key', 'keyVaultSecretName': 'gitops-private-key', 'envName': 'CLOUDSAVER_GITHUB_APP_PRIVATE_KEY'}
        c['extraSecrets'] = [binding];cfg.validate(c)
        for change in [{'appSecretName': 'clouddatabaseurl'}, {'envName': 'CLOUDSAVER_DATABASE_URL'},
                       {'keyVaultSecretName': c['secretNames']['cloudMigrationUrl']}]:
            with self.subTest(change=change):
                value = copy.deepcopy(c);value['extraSecrets'][0].update(change)
                with self.assertRaises(cfg.ConfigError):cfg.validate(value)
        c['extraSecrets'].append(copy.deepcopy(binding))
        with self.assertRaises(cfg.ConfigError):cfg.validate(c)

    def test_untrusted_proxy_cidrs(self):
        for value in ['0.0.0.0/0', '::/0', '10.0.0.1/24', 'invalid']:
            with self.subTest(value=value):
                c = sample();c['trustedProxyCidrs'] = [value]
                with self.assertRaises(cfg.ConfigError):cfg.validate(c)

    def test_unknown_keys_and_unpinned_images_rejected(self):
        for changes in [{'unexpected': True}, {'images': {**sample()['images'], 'python': 'myregistry.azurecr.io/api:latest'}}]:
            c = sample();c.update(changes)
            with self.assertRaises(cfg.ConfigError):cfg.validate(c)

    def test_duplicate_json_keys_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'duplicate.json';p.write_text('{"prefix":"one","prefix":"two"}')
            with self.assertRaises(cfg.ConfigError):cfg.load(p)

    def test_source_acceptance_blocks_confirmed_broken_source(self):
        c=accepted();c['application']['sourceRevision']=cfg.KNOWN_BLOCKED_REVISION
        with self.assertRaises(cfg.ConfigError):cfg.require_application_acceptance(c)
        c=accepted();c['application']['acceptanceRecord']=''
        with self.assertRaises(cfg.ConfigError):cfg.require_application_acceptance(c)

    def test_custom_domain_requires_a_managed_binding(self):
        c=sample();c['portalPublicUrl']='https://platform.example.com'
        with self.assertRaises(cfg.ConfigError):cfg.validate(c)
        c['portalDomain']={'hostname':'platform.example.com','certificateId':'/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg/providers/Microsoft.App/managedEnvironments/env/certificates/cert'}
        cfg.validate(c)
        c['portalDomain']['hostname']='different.example.com'
        with self.assertRaises(cfg.ConfigError):cfg.validate(c)

    def test_parameter_mapping_and_fingerprint(self):
        c=sample();params=cfg.parameters(c, False)['parameters']
        self.assertNotIn('application',params);self.assertNotIn('subscriptionId',params)
        self.assertEqual(params['deployRuntime']['value'],False)
        self.assertEqual(params['deploymentFingerprint']['value'],cfg.fingerprint(c))
        c['images']['python']=c['images']['python'].replace('0'*64,'a'*64)
        self.assertNotEqual(params['deploymentFingerprint']['value'],cfg.fingerprint(c))


class AzureWorkflowTests(unittest.TestCase):
    def test_azure_uses_explicit_subscription_and_does_not_echo_errors(self):
        run=Mock(return_value=Mock(returncode=1,stderr='secret-fixture',stdout=''))
        with self.assertRaises(deploy.DeploymentError) as error:
            deploy.Azure(accepted(),run).call('deployment','group','create')
        self.assertNotIn('secret-fixture',str(error.exception))
        self.assertIn('--subscription',run.call_args.args[0])

    def test_only_not_found_can_be_treated_as_missing(self):
        for stderr, allowed in [('ResourceNotFound',True),('AuthorizationFailed',False)]:
            run=Mock(return_value=Mock(returncode=1,stderr=stderr,stdout=''))
            azure=deploy.Azure(accepted(),run)
            if allowed:self.assertIsNone(azure.call('containerapp','show',missing_ok=True))
            else:
                with self.assertRaises(deploy.DeploymentError):azure.call('containerapp','show',missing_ok=True)

    def test_offline_check_does_not_construct_azure_client(self):
        with patch.object(deploy,'Azure') as azure, redirect_stdout(io.StringIO()):
            self.assertEqual(deploy.main(['check','--config',str(ROOT/'examples/production.json')]),0)
            azure.assert_not_called()

    def test_mutation_requires_apply_before_any_azure_call(self):
        for phase in ['jobs','migrate','runtime']:
            with patch.object(deploy,'Azure') as azure:
                with self.assertRaises(deploy.DeploymentError):deploy.main([phase,'--config',str(ROOT/'examples/production.json')])
                azure.assert_not_called()

    def test_preflight_checks_metadata_only(self):
        c=accepted();azure=Mock()
        azure.call.side_effect=[{'location':'eastus','id':'env','profiles':[{'name':'Consumption'}]},
                               {'server':'myregistry.azurecr.io','mode':'LegacyRegistryPermissions'},
                               {'rbac':True}, list(c['secretNames'].values()), {'id':'identity','clientId':'id'}]
        deploy.preflight(c,azure)
        calls=[call.args for call in azure.call.call_args_list]
        self.assertIn(('keyvault','secret','list'),[a[:3] for a in calls])
        self.assertNotIn(('keyvault','secret','show'),[a[:3] for a in calls])
        for args in calls:self.assertIn('--query',args)

    def test_abac_registry_stops_preflight(self):
        azure=Mock();azure.call.side_effect=[{'location':'eastus','profiles':[{'name':'Consumption'}]},
                                            {'server':'myregistry.azurecr.io','mode':'AbacRepositoryPermissions'}]
        with self.assertRaises(deploy.DeploymentError):deploy.preflight(accepted(),azure)

    def test_worker_transition_blocks_scheduler_and_disabled_workers(self):
        c=accepted();azure=Mock();azure.call.side_effect=[['csprod-scheduler'],['active']]
        with self.assertRaises(deploy.DeploymentError):deploy.assert_worker_transition(c,azure)

    def test_migration_failure_stops_before_cloud_job(self):
        c=accepted();azure=Mock(config=c)
        azure.call.side_effect=[{'image':c['images']['identity'],'fingerprint':cfg.fingerprint(c)},[],'platform-execution']
        waiter=Mock(side_effect=deploy.DeploymentError('failed'))
        with self.assertRaises(deploy.DeploymentError):deploy.migrate(c,azure,waiter=waiter)
        self.assertEqual(azure.call.call_count,3)
        self.assertTrue(all('csprod-migrate-cloud' not in call.args for call in azure.call.call_args_list))

    def test_stale_job_and_running_execution_never_start(self):
        c=accepted()
        for responses in [[{'image':'wrong','fingerprint':'old'}],
                          [{'image':c['images']['identity'],'fingerprint':cfg.fingerprint(c)},[{'name':'ongoing','status':'Running'}]]]:
            azure=Mock(config=c);azure.call.side_effect=responses
            with self.assertRaises(deploy.DeploymentError):deploy.migrate(c,azure)
            self.assertFalse(any(call.args[:3]==('containerapp','job','start') for call in azure.call.call_args_list))

    def test_both_migrations_are_ordered_and_receipt_matches(self):
        c=accepted();azure=Mock(config=c);fp=cfg.fingerprint(c)
        azure.call.side_effect=[{'image':c['images']['identity'],'fingerprint':fp},[],'platform-execution',
                               {'image':c['images']['python'],'fingerprint':fp},[],'cloud-execution']
        waiter=Mock();receipt=deploy.migrate(c,azure,waiter=waiter)
        self.assertEqual([j['job'] for j in receipt['jobs']],['csprod-migrate-platform','csprod-migrate-cloud'])
        self.assertEqual(receipt['fingerprint'],fp);self.assertEqual(waiter.call_count,2)

    def test_failed_and_uncertain_executions_stop(self):
        c=accepted();azure=Mock(config=c);azure.call.return_value='Failed'
        with self.assertRaises(deploy.DeploymentError):deploy.wait_execution(azure,'job','execution')
        azure.call.return_value='Running'
        with self.assertRaises(deploy.DeploymentError):
            deploy.wait_execution(azure,'job','execution',clock=Mock(side_effect=[0,1000]),pause=Mock())

    def test_receipt_must_match_and_be_reverified_against_azure(self):
        c=accepted();azure=Mock(config=c);azure.call.side_effect=['Succeeded','Failed']
        receipt={'fingerprint':cfg.fingerprint(c),'jobs':[{'job':f'csprod-migrate-{x}','execution':x,'status':'Succeeded'} for x in ['platform','cloud']]}
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'receipt.json';path.write_text(json.dumps(receipt))
            with self.assertRaises(deploy.DeploymentError):deploy.verify_receipt(c,azure,path)
            receipt['fingerprint']='stale';path.write_text(json.dumps(receipt));azure.call.reset_mock()
            with self.assertRaises(deploy.DeploymentError):deploy.verify_receipt(c,azure,path)
            azure.call.assert_not_called()

    def test_successful_receipt_and_private_atomic_write(self):
        c=accepted();azure=Mock(config=c);azure.call.return_value='Succeeded'
        receipt={'fingerprint':cfg.fingerprint(c),'jobs':[{'job':f'csprod-migrate-{x}','execution':x,'status':'Succeeded'} for x in ['platform','cloud']]}
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'receipt.json'
            with patch.object(deploy,'receipt_path',return_value=path):deploy.write_receipt(c,receipt)
            self.assertEqual(path.stat().st_mode & 0o777,0o600)
            self.assertEqual(deploy.verify_receipt(c,azure,path),receipt)

    def test_what_if_uses_only_nonsecret_parameters(self):
        c=accepted();azure=Mock(config=c)
        def inspect(*args):
            self.assertEqual(args[:3],('deployment','group','what-if'))
            self.assertIn('--no-pretty-print',args)
            path=args[args.index('--parameters')+1][1:]
            value=json.loads(Path(path).read_text())
            self.assertEqual(value['parameters']['deployRuntime']['value'],True)
            self.assertNotIn('postgresql://',json.dumps(value))
            self.assertEqual(Path(path).stat().st_mode & 0o777,0o600)
            return []
        azure.call.side_effect=inspect
        self.assertEqual(deploy.deploy_template(c,azure,runtime=True,what_if=True),[])


class CompiledTemplateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path=ROOT/'dist/main.json'
        if not path.exists():raise unittest.SkipTest('Build Bicep into dist/ before compiled-template tests')
        cls.main=json.loads(path.read_text());cls.resources=cls.main['resources']

    def params(self,name):return {k:v['value'] for k,v in self.resources[name]['properties']['parameters'].items()}

    def test_only_two_external_web_apps(self):
        apps=['identity','portal','scanner','tenant','analytics','notifications','gateway','dashboard','worker','scheduler','dispatcher']
        self.assertEqual([n for n in apps if self.params(n)['external']],['portal','dashboard'])
        self.assertEqual(self.params('gateway')['targetPort'],8000)
        for name in apps:self.assertIn("parameters('deployRuntime')",self.resources[name]['condition'])

    def test_worker_conditions_and_singleton_limits(self):
        for name in ['worker','scheduler','dispatcher']:self.assertIn("parameters('workers')",self.resources[name]['condition'])
        for name in ['portal','tenant','scheduler']:
            self.assertEqual(self.params(name)['minReplicas'],1)
            self.assertEqual(self.params(name)['maxReplicas'],1)
        self.assertEqual(self.params('worker')['targetPort'],0)

    def test_migration_jobs_are_manual_and_separate(self):
        for name in ['migrateplatform','migratecloud']:
            resource=self.resources[name]
            self.assertNotIn('condition',resource)
            job=resource['properties']['template']['resources']['job']
            config=resource['properties']['template']['variables']['jobConfiguration']
            self.assertEqual(config['triggerType'],'Manual')
            self.assertEqual(config['replicaRetryLimit'],0)
            self.assertEqual(config['manualTriggerConfig'],{'parallelism':1,'replicaCompletionCount':1})
            self.assertEqual(len(resource['properties']['template']['variables']['jobTemplate']['containers'][0]['env']),1)
            self.assertEqual(len(config['secrets']),1)
            self.assertNotIn('value',config['secrets'][0])
        self.assertNotEqual(self.params('migrateplatform')['identityId'],self.params('identity')['configIdentityId'])

    def test_vault_roles_are_scoped_to_secrets(self):
        template=self.resources['vaultAccess']['properties']['template']
        grants=template['resources']['grants']
        self.assertIn('Microsoft.KeyVault/vaults/secrets',grants['scope'])
        self.assertIn('4633458b-17de-408a-b874-0445c86b69e6',template['variables']['secretsUserRoleId'])

    def test_migration_owners_not_in_runtime_permission_sets(self):
        specs=self.main['variables']['specs']
        for item in specs:
            if item['name'] not in ['migrate-platform','migrate-cloud']:
                self.assertNotIn('cloudMigrationUrl',item['secrets']);self.assertNotIn('identityMigrationUrl',item['secrets'])
        self.assertEqual(next(v['secrets'] for v in specs if v['name']=='dashboard'),[])

    def test_cloud_identity_only_attached_to_cloud_workloads(self):
        apps=['identity','portal','scanner','tenant','analytics','notifications','gateway','dashboard','worker','scheduler','dispatcher']
        self.assertEqual([n for n in apps if 'cloudIdentityId' in self.params(n)],['scanner','worker'])
