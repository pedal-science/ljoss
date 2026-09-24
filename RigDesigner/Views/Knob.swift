import SwiftUI

import math_h

struct Knob: View {
    @State var range: Range<Double>
    @State var value: Double
    let circle: Double = .pi * 2
    var percent: Double {
        let r: Double = range.upperBound - range.lowerBound
        let v: Double = value - range.lowerBound
        return v / r
    }
    let min: Double = 0.13
    let max: Double = 0.88
    var valueMax: Double {
        get {
            return min + (max - min) * percent
        }
    }
    let circleWidth: CGFloat = 40.0
    
    var body: some View {
        ZStack {
            ZStack {
                Circle()
                    .trim(from: min, to: max)
                    .stroke(lineWidth: circleWidth)
                    .fill(Color.secondary)
                
                 Circle()
                    .trim(from: min, to: min + (max - min) * percent)
                    .stroke(lineWidth: circleWidth)
                    .fill(Color.accentColor)

            }
            .padding(circleWidth / 2)
            .rotationEffect(Angle(radians: circle / 4))
            VStack {
                Text("\(value)")
                    .font(.title)
            }
        }.padding()
    }
}


struct Knob_Previews: PreviewProvider {
    static var previews: some View {
        Knob(range: Range<Double>(uncheckedBounds: (lower: 0.0, upper: 10.0)), value: 10.0)
    }
}
