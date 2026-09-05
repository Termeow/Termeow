import os

public enum AppLog {
    public static let ssh = Logger(subsystem: "cn.termeow.Termeow", category: "ssh")
    public static let terminal = Logger(subsystem: "cn.termeow.Termeow", category: "terminal")
    public static let storage = Logger(subsystem: "cn.termeow.Termeow", category: "storage")
}
