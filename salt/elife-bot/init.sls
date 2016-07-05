elife-bot-deps:
    pkg.installed:
        - pkgs:
            - libxml2-dev 
            - libxslt-dev
            - lzma-dev # provides 'lz' for compiling lxml
            - imagemagick
            - libmagickwand-dev
        - require:
            - pkg: python-dev

elife-bot-repo:    
    git.latest:
        - name: git@github.com:elifesciences/elife-bot.git
        - rev: {{ salt['elife.cfg']('project.revision', 'project.branch', 'master') }}
        - branch: {{ salt['elife.branch']() }}
        - force_fetch: True
        - force_checkout: True
        - force_reset: True
        - target: /opt/elife-bot

    file.directory:
        - name: /opt/elife-bot
        - user: {{ pillar.elife.deploy_user.username }}
        - group: {{ pillar.elife.deploy_user.username }}
        - recurse:
            - user
            - group
        - require:
            - git: elife-bot-repo

elife-bot-tmp-link:
    file.symlink:
        - name: /opt/elife-bot/tmp
        - target: /tmp
        - require:
            - file: elife-bot-repo

elife-bot-virtualenv:
    virtualenv.managed:
        - user: {{ pillar.elife.deploy_user.username }}
        - name: /opt/elife-bot/venv/
        - requirements: /opt/elife-bot/requirements.txt
        - require:
            - file: elife-bot-repo
            - pkg: python-pip

elife-bot-settings:
    file.managed:
        - user: {{ pillar.elife.deploy_user.username }}
        - name: /opt/elife-bot/settings.py
        - source: salt://elife-bot/config/opt-elife-bot-settings.py
        - require:
            - git: elife-bot-repo

elife-bot-redis-settings:
    file.managed:
        - name: /etc/redis/redis.conf
        - source: salt://elife-bot/config/etc-redis-redis.conf
        - template: jinja
        - watch_in:
            - service: redis-server

#
#
#

elife-poa-xml-generation-repo:
    git.latest:
        - name: git@github.com:elifesciences/elife-poa-xml-generation.git
        - target: /opt/elife-poa-xml-generation

    file.directory:
        - name: /opt/elife-poa-xml-generation
        - user: {{ pillar.elife.deploy_user.username }}
        - group: {{ pillar.elife.deploy_user.username }}
        - recurse:
            - user
            - group
        - require:
            - git: elife-poa-xml-generation-repo

elife-poa-xml-generation-settings:
    file.managed:
        - user: {{ pillar.elife.deploy_user.username }}
        - name: /opt/elife-poa-xml-generation/settings.py
        - source: salt://elife-bot/config/opt-elife-poa-xml-generation-settings.py
        - require:
            - git: elife-poa-xml-generation-repo


#
# cron jobs
#

{% for botenv in ['live', 'test'] %}

elife-bot-{{ botenv }}-cron-file:
    file.managed:
        - user: {{ pillar.elife.deploy_user.username }}
        - name: /home/{{ pillar.elife.deploy_user.username }}/{{ botenv }}-elife-bot.cron
        - source: salt://elife-bot/config/home-deployuser-elife-bot.cron
        - template: jinja
        - context:
            env: {{ botenv }}
        - require:
            - file: elife-poa-xml-generation-settings # arbitrary

{% endfor %}

#
# strip coverletter
#

strip-coverletter-deps:
    pkg.installed:
        - pkgs:
            - xpdf-utils

    archive.extracted:
        - name: /opt/pdfsam/
        #- source: http://garr.dl.sourceforge.net/project/pdfsam/pdfsam/2.2.4/pdfsam-2.2.4-out.zip
        - source: https://github.com/torakiki/pdfsam-v2/releases/download/v2.2.4/pdfsam-2.2.4-out.zip
        - archive_format: zip
        - source_hash: md5=29ab520b1bf453af7394760b66d43453
        - unless:
            - test -d /opt/pdfsam/

    cmd.run:
        - name: |
            echo -e '#!/bin/bash\ncd /opt/pdfsam/bin/\nsh run-console.sh "$@"' > /usr/bin/pdfsam-console
            chmod +x /usr/bin/pdfsam-console
        - unless:
            - test -f /usr/bin/pdfsam-console

install-strip-coverletter:
    git.latest:
        - name: https://github.com/elifesciences/strip-coverletter
        - target: /opt/strip-coverletter

#
# clean up the temporary files that accumulate
#

elife-bot-temporary-files-cleaner:
    file.managed:
        - name: /opt/rmrf_enter/elife-bot.py
        - source: salt://elife-bot/config/opt-rmrf_enter-elife-bot.py
        - makedirs: True
        - require:
            - pip: global-python-requisites

    # 2am, every day
    cron.present:
        - identifier: temp-files-cleaner
        - name: python /opt/rmrf_enter/elife-bot.py > /dev/null
        - minute: 0
        - hour: 2
        - require:
            - file: elife-bot-temporary-files-cleaner


# WARNING - this can be a little buggy.
# temporary files accumulate like crazy in production elife-bot
# on AWS we mount the /tmp dir on a separate EBS volume

# dir is a mount point
#- grep -qs '/var/lib/docker/' /proc/mounts

# volume to mount exists and is block special (-b)
#- test -b /dev/xvdh

format-temp-volume:
    cmd.run: 
        - name: mkfs -t ext4 /dev/xvdh
        - onlyif:
            # disk exists
            - test -b /dev/xvdh
        - unless:
            # volume exists and is already formatted
            - file --special-files /dev/xvdh | grep ext4

mount-temp-volume:
    mount.mounted:
        - name: /tmp
        - device: /dev/xvdh
        - fstype: ext4
        - mkmnt: True
        - opts:
            - defaults
        - require:
            - cmd: format-temp-volume
        - onlyif:
            # disk exists
            - test -b /dev/xvdh
        - unless:
            # mount point already has a volume mounted
            - cat /proc/mounts | grep --quiet --no-messages /tmp/

    cmd.run:
        - name: chmod -R 777 /tmp
        - require:
            - mount: mount-temp-volume

app-done:
    cmd.run: 
        - name: echo "app is done installing"
        - require:
            - file: elife-bot-settings
            - file: elife-bot-redis-settings
            - file: elife-bot-tmp-link
            - virtualenv: elife-bot-virtualenv
            - cmd: mount-temp-volume

register-swf:
    cmd.run:
        - name: venv/bin/python register.py -e {{ pillar.elife.env }}
        - cwd: /opt/elife-bot
        - require:
            - cmd: app-done

{% set processes = {'decider': 3, 'worker': 5, 'queue_worker': 3, 'queue_workflow_starter': 5, 'shimmy': 1} %}
{% for process, number in processes.iteritems() %}
elife-bot-{{ process }}-service:
    file.managed:
        - name: /etc/init/elife-bot-{{ process }}.conf
        - source: salt://elife-bot/config/etc-init-elife-bot-process.conf
        - template: jinja
        - context:
            process: {{ process }}
        - require:
            - cmd: register-swf

elife-bot-{{ process }}s-task:
    file.managed:
        - name: /etc/init/elife-bot-{{ process }}s.conf
        - source: salt://elife-bot/config/etc-init-elife-bot-processes.conf
        - template: jinja
        - context:
            process: {{ process }}
            number: {{ number }}
        - require:
            - file: elife-bot-{{ process }}-service
{% endfor %}