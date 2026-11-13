import Foundation

enum InstallerCompatibility {
    static func requiresFullX87Precision(_ executable: URL) -> Bool {
        if executable.pathExtension.lowercased() == "msi" { return true }
        guard executable.pathExtension.lowercased() == "exe" else { return false }
        let name = executable.lastPathComponent.lowercased()
        if ["setup.exe", "install.exe", "installer.exe", "uninstall.exe", "uninstaller.exe", "unwise.exe"].contains(name) {
            return true
        }
        if name.range(of: #"^unins[0-9]{3}\.exe$"#, options: .regularExpression) != nil { return true }

        // Renamed installers keep their engine signature. Read a bounded PE
        // header rather than mapping a potentially multi-gigabyte installer.
        guard let file = try? FileHandle(forReadingFrom: executable) else { return false }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 1_048_576), header.count >= 64,
              header[0] == 0x4d, header[1] == 0x5a else { return false }
        let pe = (0..<4).reduce(0) { $0 | Int(header[60 + $1]) << (8 * $1) }
        guard pe <= header.count - 4, header[pe..<(pe + 4)].elementsEqual([0x50, 0x45, 0, 0]) else { return false }
        return ["Inno Setup Setup Data", "Inno Setup Uninstall Log", "NullsoftInst"].contains {
            header.range(of: Data($0.utf8)) != nil
        }
    }
}
