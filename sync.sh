#! /bin/bash
#exec rsync -ai --exclude .git --delete --delete-excluded ./ bremer.arch.suse.de:/home/rules/
rsync -a ./ wotan.suse.de:/suse/mwilck/rules/
rsync -ai --exclude .git  ./ bremer.arch.suse.de:/home/rules/
