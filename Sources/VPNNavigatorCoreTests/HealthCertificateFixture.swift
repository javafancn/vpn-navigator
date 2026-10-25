import Foundation

// Synthetic self-signed public certificate; its private key is not retained.
enum HealthCertificateFixture {
    static let pem = """
    -----BEGIN CERTIFICATE-----
    MIIBUTCB+KADAgECAgRq3gBwMAoGCCqGSM49BAMCMDExLzAtBgNVBAMMJlZQTiBO
    YXZpZ2F0b3Igc3ludGhldGljIGhlYWx0aCBmaXh0dXJlMB4XDTMwMDEwMTAwMDAw
    MFoXDTQwMDEwMTAwMDAwMFowMTEvMC0GA1UEAwwmVlBOIE5hdmlnYXRvciBzeW50
    aGV0aWMgaGVhbHRoIGZpeHR1cmUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQw
    CnQ+jIx9QBN4yasfgydc09uTgeGed+/cu82t0/mcwTYq5HqTSF4qYq8Z1D+ZVlfz
    cEII4WxymLArFGJcx/RpMAoGCCqGSM49BAMCA0gAMEUCIQCvQtJSh4rfWP7beCqR
    kY3eO7rRc3/9MbvsyxwKqs8FWgIgDCVFMsyTMtVkAm/NjZMFqeseV4YriWS2iWz5
    4gHRHso=
    -----END CERTIFICATE-----
    """
    static let start = Date(timeIntervalSince1970: 1893456000)
    static let end = Date(timeIntervalSince1970: 2208988800)
    static let config = "client\ndev tun\nremote fixture.example 1194\n<ca>\n" + pem + "\n</ca>\nauth-user-pass\n"
}
