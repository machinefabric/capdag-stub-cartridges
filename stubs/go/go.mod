module __CARTRIDGE_NAME__

go 1.21

// capdag-go's newest PUBLISHED tag, not its working version.
//
// A stub is built by fetching this from GitHub, so it can only ask for a
// version that has been released. Stamping the working version -- which is
// always ahead of the newest tag -- asked for one no tag satisfies and
// resolved whatever older one it could, so every fix to the mirror stayed
// invisible to the stub suite until a release happened to catch up.
require github.com/machinefabric/capdag-go v1.386.0
