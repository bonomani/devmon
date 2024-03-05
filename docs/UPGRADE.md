# Upgrade #

These instructions complement the documentation found in `devmon/docs/INSTALLLATION.md`. Please ensure that you are operating on the same server as the Xymon Display server.

## Prerequisites ##  
- A working installation of Xymon and Devmon!

## Instructions ##

1. Replace the following folders:
   - `devmon/modules/`
   - `devmon/templates/`

2. Replace the file:
   - `devmon/devmon`

3. Create a backup of:
   - `devmon/hosts.db`

4. Perform a discovery:
   - `./devmon -read`

5. Restart Xymon.
