CHECK IF MY COMPUTER IS OK
Run:
~/baby-step/check-system.sh

UPDATE MY COMPUTER
Run:
~/baby-step/update-system.sh

UPDATE AND SAVE MY CONFIG TO GITHUB
Run:
~/baby-step/update-and-push.sh

IF SOMETHING FAILS
Do not run random commands.
Copy the ERROR message and show it to Codex or ChatGPT.
Detailed logs are stored in:
~/baby-step/logs

IMPORTANT
Run these commands as your normal user.
Do not put sudo in front of them.
The update tools will ask for your password when it is actually needed.
Nothing appears while you type your password. That is normal. Press Enter.

REBUILD WITHOUT DOWNLOADING UPDATES
Run:
~/baby-step/rebuild-system.sh

SAVE CONFIG LOCALLY WITHOUT COMMITTING OR PUSHING
Run:
~/baby-step/backup-config.sh

IF A NEW SYSTEM WAS ACTIVATED AND THEN BROKE
Open Terminal.
Copy this command:
sudo nixos-rebuild switch --rollback
Paste it.
Press Enter.
Type your password and press Enter.
Then stop and show Codex or ChatGPT what happened.

IF THE COMPUTER CANNOT REACH THE LOGIN SCREEN
Restart the computer.
In the boot menu, choose an older NixOS generation.
Do not delete old generations while troubleshooting.

The tools automatically detect the flake configuration.
You do not need to remember that the current target is /etc/nixos#tonelico.
