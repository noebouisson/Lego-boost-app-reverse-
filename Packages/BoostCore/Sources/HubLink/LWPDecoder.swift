import Foundation

public enum LWPDecodingError: Error, Equatable {
    case tooShort
    case lengthMismatch(declared: Int, actual: Int)
    case malformed(type: UInt8)
}

/// Décodage des messages montants.
public enum LWPDecoder {

    /// Décode une notification complète de la caractéristique 1624.
    public static func decode(_ data: Data) throws -> LWPMessage {
        let bytes = [UInt8](data)
        guard bytes.count >= 3 else { throw LWPDecodingError.tooShort }

        // Longueur sur 1 octet, ou 2 si le bit 7 du premier est levé (doc §3.2).
        var declared = Int(bytes[0])
        var headerSize = 3
        if bytes[0] & 0x80 != 0 {
            guard bytes.count >= 4 else { throw LWPDecodingError.tooShort }
            declared = Int(bytes[0] & 0x7F) | (Int(bytes[1]) << 7)
            headerSize = 4
        }
        guard declared >= headerSize, declared <= bytes.count else {
            throw LWPDecodingError.lengthMismatch(declared: declared, actual: bytes.count)
        }

        let type = bytes[headerSize - 1]
        let body = Array(bytes[headerSize..<declared])

        guard let messageType = MessageType(rawValue: type) else {
            return .unknown(type: type, payload: Data(body))
        }

        switch messageType {
        case .hubProperties:
            guard body.count >= 2 else { throw LWPDecodingError.malformed(type: type) }
            return .hubProperty(HubPropertyUpdate(property: body[0], operation: body[1], payload: Data(body.dropFirst(2))))

        case .hubActions:
            guard body.count >= 1 else { throw LWPDecodingError.malformed(type: type) }
            return .hubAction(body[0])

        case .hubAlerts:
            guard body.count >= 2 else { throw LWPDecodingError.malformed(type: type) }
            return .hubAlert(type: body[0], operation: body[1], payload: body.count > 2 ? body[2] : nil)

        case .hubAttachedIO:
            return .attachedIO(try decodeAttachedIO(body, type: type))

        case .genericError:
            guard body.count >= 2 else { throw LWPDecodingError.malformed(type: type) }
            return .error(commandType: body[0], code: body[1])

        case .portInformation:
            guard body.count >= 2 else { throw LWPDecodingError.malformed(type: type) }
            var info = PortInformation(port: body[0], informationType: body[1], capabilities: 0, modeCount: 0,
                                       inputModes: 0, outputModes: 0, raw: Data(body.dropFirst(2)))
            if body[1] == PortInformationType.modeInfo.rawValue {
                guard body.count >= 8 else { throw LWPDecodingError.malformed(type: type) }
                info.capabilities = body[2]
                info.modeCount = body[3]
                info.inputModes = UInt16(body[4]) | (UInt16(body[5]) << 8)
                info.outputModes = UInt16(body[6]) | (UInt16(body[7]) << 8)
            }
            return .portInformation(info)

        case .portModeInformation:
            guard body.count >= 3 else { throw LWPDecodingError.malformed(type: type) }
            return .portModeInformation(PortModeInformation(port: body[0], mode: body[1], informationType: body[2],
                                                            payload: Data(body.dropFirst(3))))

        case .portValueSingle:
            // La doc autorise plusieurs ports par message, mais la taille de chaque
            // valeur dépend du format du port : on traite le cas courant, un seul port.
            guard body.count >= 1 else { throw LWPDecodingError.malformed(type: type) }
            return .portValue(port: body[0], payload: Data(body.dropFirst(1)))

        case .portInputFormatSingle:
            guard body.count >= 7 else { throw LWPDecodingError.malformed(type: type) }
            let delta = UInt32(body[2]) | (UInt32(body[3]) << 8) | (UInt32(body[4]) << 16) | (UInt32(body[5]) << 24)
            return .portInputFormat(PortInputFormat(port: body[0], mode: body[1], deltaInterval: delta,
                                                    notificationEnabled: body[6] != 0))

        case .portOutputCommandFeedback:
            guard body.count >= 2, body.count % 2 == 0 else { throw LWPDecodingError.malformed(type: type) }
            var feedbacks: [PortFeedback] = []
            var index = 0
            while index + 1 < body.count {
                feedbacks.append(PortFeedback(port: body[index], flags: FeedbackFlags(rawValue: body[index + 1])))
                index += 2
            }
            return .outputFeedback(feedbacks)

        case .portInformationRequest, .portModeInformationRequest, .portInputFormatSetupSingle,
             .portValueCombined, .portOutputCommand:
            return .unknown(type: type, payload: Data(body))
        }
    }

    private static func decodeAttachedIO(_ body: [UInt8], type: UInt8) throws -> AttachedIOEvent {
        guard body.count >= 2 else { throw LWPDecodingError.malformed(type: type) }
        let port = body[0]
        switch body[1] {
        case 0x00:
            return .detached(port: port)
        case 0x01:
            guard body.count >= 4 else { throw LWPDecodingError.malformed(type: type) }
            return .attached(port: port, ioType: IOType(rawValue: UInt16(body[2]) | (UInt16(body[3]) << 8)))
        case 0x02:
            guard body.count >= 6 else { throw LWPDecodingError.malformed(type: type) }
            return .attachedVirtual(port: port, ioType: IOType(rawValue: UInt16(body[2]) | (UInt16(body[3]) << 8)),
                                    portA: body[4], portB: body[5])
        default:
            throw LWPDecodingError.malformed(type: type)
        }
    }
}
