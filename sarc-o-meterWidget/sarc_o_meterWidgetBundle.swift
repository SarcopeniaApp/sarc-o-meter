//
//  sarc_o_meterWidgetBundle.swift
//  sarc-o-meterWidget
//
//  Created by Surya on 01/09/26.
//

import WidgetKit
import SwiftUI

@main
struct sarc_o_meterWidgetBundle: WidgetBundle {
    var body: some Widget {
        sarc_o_meterWidget()
        sarc_o_meterWidgetControl()
        ModelDownloadLiveActivityWidget()
    }
}
