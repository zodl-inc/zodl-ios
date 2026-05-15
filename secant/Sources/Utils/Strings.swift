import Foundation

// TODO: [#695] This should have a #DEBUG tag, but if so, it's not possible to compile this on release mode and submit it to testflight https://github.com/zcash/ZcashLightClientKit/issues/695
extension String {
    init<T>(dumping value: T) {
        var output = String()
        dump(value, to: &output)
        self.init(stringLiteral: output)
    }
}

extension String {
    var zip316: String {
        self.count > 20
        ? "\(self.prefix(20))..."
        : self
    }

    var trailingZip316: String {
        if self.count > 25 {
            return "\(self.prefix(20))...\(self.suffix(4))"
        } else {
            return self.zip316
        }
    }
    
    var truncateMiddle: String {
        if self.count > 10 {
            return "\(self.prefix(5))...\(self.suffix(5))"
        } else {
            return self.zip316
        }
    }

    var truncateMiddle10: String {
        if self.count > 20 {
            return "\(self.prefix(10))...\(self.suffix(10))"
        } else {
            return self.truncateMiddle
        }
    }

    var localeUsdDecimal: Decimal? {
        let usFormatter = NumberFormatter()
        usFormatter.locale = Locale(identifier: "en_US")
        usFormatter.numberStyle = .decimal

        guard let number = usFormatter.number(from: self) else {
            return nil
        }

        return Decimal(number.doubleValue)
    }

    var localeUsd: String? {
        self.localeUsdDecimal?.formatted(.currency(code: "USD"))
    }
    
    var localeString: String? {
        self.localeUsdDecimal?.formatted()
    }
    
    var usDecimal: Decimal? {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        return formatter.number(from: self)?.decimalValue
    }
}

extension String: @retroactive Error {}

extension String {
    private static let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,6}"
    private static let phoneRegex = "^^\\+(?:[0-9]?){6,14}[0-9]$"

    enum ValidationType: Equatable {
        case customFloatingPoint(NumberFormatter)
        case custom(String)
        case email
        case floatingPoint
        case maxLength(Int)
        case minLength(Int)
        case phoneNumber

        func isValid(text: String) -> Bool {
            switch self {
            case .customFloatingPoint(let numberFormatter):
                return text.validate(using: numberFormatter)

            case .custom(let regex):
                return text.validate(using: regex)

            case .email:
                return text.validate(using: .emailRegex)

            case .floatingPoint:
                return NumberFormatter.zcashNumberFormatter.number(from: text) != nil

            case .maxLength(let length):
                return text.count <= length && !text.isEmpty

            case .minLength(let length):
                return text.count >= length

            case .phoneNumber:
                return text.validate(using: .phoneRegex)
            }
        }
    }

    private func validate(using numberFormatter: NumberFormatter) -> Bool {
        numberFormatter.number(from: self) != nil
    }

    private func validate(using regex: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: regex) else { return false }

        return regex.firstMatch(
            in: self,
            options: [],
            range: NSRange(location: 0, length: self.utf16.count)
        ) != nil
    }

    func isValid(for validationType: ValidationType?) -> Bool {
        guard let validationType else { return true }

        return validationType.isValid(text: self)
    }
}
