//
//  AnimatedQRCode.swift
//  keystone-sdk-ios-demo
//
//  Created by LiYan on 4/13/23.
//

import SwiftUI
@preconcurrency import KeystoneSDK
import URKit
import UIKit

struct AnimatedQRCode: View {
    @StateObject private var viewModel: ViewModel
    private var timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
    let size: CGFloat

    init(urEncoder: UREncoder, size: CGFloat){
        self._viewModel = StateObject(wrappedValue: ViewModel(urEncoder: urEncoder))
        self.size = size
    }

    var body: some View {
        Image(uiImage: UIImage(data: viewModel.content) ?? UIImage())
            .resizable()
            .frame(width: size, height: size)
            .onReceive(timer) { _ in
                if viewModel.errorMessage.isEmpty {
                    viewModel.nextQRCode()
                } else {
                    timer.upstream.connect().cancel()
                }
            }
    }
}

struct AnimatedQRCode_Previews: PreviewProvider {
    static var previews: some View {
        let keystoneSDK = KeystoneSDK()
        KeystoneSDK.maxFragmentLen = 200 // default 400
        let qrCode: UREncoder = try! keystoneSDK.btc.generatePSBT(psbt: MockData.psbt)
        return AnimatedQRCode(urEncoder: qrCode, size: 250)
    }
}

extension AnimatedQRCode {
    final class ViewModel: ObservableObject {
        @Published var content: Data = Data()
        @Published var errorMessage: String = ""
        private var encoder: UREncoder;

        init (urEncoder: UREncoder) {
            self.encoder = urEncoder;
            self.content = getNextQRCode();
        }

        func getQRCodeDate(from string: String) -> Data? {
            let data = string.data(using: String.Encoding.ascii)

            if let filter = CIFilter(name: "CIQRCodeGenerator") {
                filter.setValue(data, forKey: "inputMessage")
                let transform = CGAffineTransform(scaleX: 4, y: 4)

                if let output = filter.outputImage?.transformed(by: transform) {
                    return UIImage(ciImage: output).pngData()
                }
            }
            return "".data(using: .utf8)
        }
        
        func getNextQRCode() -> Data{
            let qrCode = encoder.nextPart()
            return getQRCodeDate(from: qrCode) ?? Data();
        }
        
        func nextQRCode(){
            if(encoder.isSinglePart){
                return;
            }
            self.content = getNextQRCode();
        }
    }
}

extension String {
    var hexadecimal: Data {
        var data = Data(capacity: count / 2)

        let regex = try! NSRegularExpression(pattern: "[0-9a-f]{1,2}", options: .caseInsensitive)
        regex.enumerateMatches(in: self, range: NSRange(startIndex..., in: self)) { match, _, _ in
            let byteString = (self as NSString).substring(with: match!.range)
            let num = UInt8(byteString, radix: 16)!
            data.append(num)
        }
        guard data.count > 0 else { return Data() }
        return data
    }
}

class MockData {
    static let psbt = "70736274ff0100710200000001a6e52d0cf7bec16c454dc590966906f2f711d2ffb720bf141b41fd0cd3146a220000000000ffffffff02809698000000000016001473071357788c861241e6e991cc1f7933aa87444440ff100500000000160014d98f4c248e06e54d08bafdc213912aca80c0a34a000000000001011f00e1f505000000001600147ced797aa1e84df81e4b9dc8a46b8db7f4abae9122060341d94247fabfc265035f0a51bcfaca3b65709a7876698769a336b4142faa4bad18f23f9fd254000080000000800000008000000000000000000000220203ab7173024786ba14179c33db3b7bdf630039c24089409637323b560a4b1d025618f23f9fd2540000800000008000000080010000000000000000".hexadecimal
}
