import Foundation

// coveyd - the daemon entry point. There is no runtime in slice 1;
// the IPC server and the real launch arrive in slice 2.
FileHandle.standardError.write(Data("coveyd: no runtime yet (slice 1)\n".utf8))
