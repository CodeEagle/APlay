import CryptoKit

extension Data {
    public var md5: String {
        let val = Insecure.MD5.hash(data: self)
        return val.description.replacingOccurrences(of: "MD5 digest: ", with: "")
    }
}
