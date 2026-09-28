# Linux fleets: Ansible, Puppet, Chef, Salt

On Linux, provisioning is three things: the signed APT repository, the
`edamame-posture` package (it installs and enables `edamame_posture.service`),
and `/etc/edamame_posture.conf` (`root:root 0600`, keys in
[configuration-reference.md](configuration-reference.md#linux-etcedamame_postureconf)).
Restart the service when the file changes. The same applies to desktops with
the `edamame-security` GUI, which uses this service.

## Ansible (role included)

[`ansible/roles/edamame`](../ansible/roles/edamame) targets Debian, Ubuntu
and Raspberry Pi OS. It checks the repository key fingerprint, installs the
package (pinned or latest, `force-confold`), templates the conf with
`no_log`, writes the systemd drop-in for the model / base URL, and restarts
the service through a handler only when something changed.

```sh
cd ansible
cp group_vars/vault.example.yml group_vars/edamame_hosts/vault.yml   # edit, then:
ansible-vault encrypt group_vars/edamame_hosts/vault.yml
ansible-playbook -i inventory playbook.example.yml --ask-vault-pass
```

Main variables (see [defaults/main.yml](../ansible/roles/edamame/defaults/main.yml)):
`edamame_user`, `edamame_domain`, `edamame_pin` (vault),
`edamame_llm_provider` (`portal|claude|openai|ollama|none`),
`edamame_llm_api_key` (vault), `edamame_llm_model`, `edamame_llm_base_url`,
`edamame_agentic_mode`, `edamame_version`, `edamame_install_app`, and the
network monitoring flags. The role owns the whole conf file: values not set
in Ansible (for example Slack tokens set by hand) are not preserved.

Unlike the shell script, the role does not support Alpine (APK); use the
script there.

## Puppet (sketch, not tested)

```puppet
apt::source { 'edamame':
  location => 'https://edamame.s3.eu-west-1.amazonaws.com/repo',
  release  => 'stable',
  repos    => 'main',
  key      => {
    'name'   => 'edamame.gpg',
    'source' => 'https://edamame.s3.eu-west-1.amazonaws.com/repo/public.key',
  },
}
-> package { 'edamame-posture':
  ensure          => installed,
  install_options => ['-o', 'Dpkg::Options::=--force-confold'],
}
-> file { '/etc/edamame_posture.conf':
  owner     => 'root', group => 'root', mode => '0600',
  content   => Sensitive(epp('profile/edamame_posture.conf.epp', {
    'pin' => lookup('edamame::pin'), 'llm_api_key' => lookup('edamame::llm_api_key') })),
  show_diff => false,
}
~> service { 'edamame_posture': ensure => running, enable => true }
```

Verify the key fingerprint (`D1C58B47675E486792DAFBAE42A2002B57F1A203`)
when you first import it; store secrets in Hiera with eyaml.

## Chef (sketch, not tested)

```ruby
apt_repository 'edamame' do
  uri          'https://edamame.s3.eu-west-1.amazonaws.com/repo'
  distribution 'stable'
  components   ['main']
  key          'https://edamame.s3.eu-west-1.amazonaws.com/repo/public.key'
  signed_by    true
end

package 'edamame-posture' do
  options '-o Dpkg::Options::=--force-confold'
end

template '/etc/edamame_posture.conf' do
  source    'edamame_posture.conf.erb'
  owner     'root'
  group     'root'
  mode      '0600'
  sensitive true
  variables(pin: chef_vault_item('edamame', 'hub')['pin'],
            llm_api_key: chef_vault_item('edamame', 'llm')['key'])
  notifies  :restart, 'service[edamame_posture]'
end

service 'edamame_posture' do
  action [:enable, :start]
end
```

## Salt (sketch, not tested)

```yaml
edamame-repo:
  pkgrepo.managed:
    - name: deb [signed-by=/usr/share/keyrings/edamame.gpg] https://edamame.s3.eu-west-1.amazonaws.com/repo stable main
    - file: /etc/apt/sources.list.d/edamame.list
    - key_url: https://edamame.s3.eu-west-1.amazonaws.com/repo/public.key
    - aptkey: False

edamame-posture:
  pkg.installed:
    - require: [pkgrepo: edamame-repo]

/etc/edamame_posture.conf:
  file.managed:
    - source: salt://edamame/edamame_posture.conf.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0600'
    - show_changes: False
    - context:
        pin: {{ pillar['edamame']['pin'] }}
        llm_api_key: {{ pillar['edamame']['llm_api_key'] }}

edamame_posture:
  service.running:
    - enable: True
    - watch: [file: /etc/edamame_posture.conf]
```

For all three, the conf template can be adapted from
[the Ansible template](../ansible/roles/edamame/templates/edamame_posture.conf.j2):
quote every value and escape `\` and `"`.

## cloud-init / golden images

Run the shell script from `runcmd` with the variables coming from your
secret source (not from user-data stored in plain text when avoidable):

```yaml
#cloud-config
write_files:
  - path: /root/edamame.env
    permissions: '0600'
    content: |
      EDAMAME_USER=ci-fleet
      EDAMAME_DOMAIN=example.com
      EDAMAME_PIN_FILE=/root/edamame_pin
      EDAMAME_LLM_PROVIDER=portal
      EDAMAME_LLM_API_KEY_FILE=/root/edamame_llm_key
runcmd:
  - set -a; . /root/edamame.env; set +a; sh /root/install-edamame-posture.sh
```

In a golden image, install the package but leave `/etc/edamame_posture.conf`
at its packaged (empty) values and let first boot write it, so the PIN and
the key are not baked into the image.
