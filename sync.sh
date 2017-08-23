#! /bin/bash
exec rsync -ai --exclude .git --delete --delete-excluded ./ bremer.arch.suse.de:/home/rules/
