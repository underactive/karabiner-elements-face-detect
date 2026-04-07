@main
struct FaceProfileEntry {
    static func main() {
        let daemon = FaceProfileDaemon()
        daemon.run()
    }
}
