//
//  ScheduleWidgetBundle.swift
//  ScheduleWidget
//
//  Created by Кирилл Сорочук on 24.08.2026.
//

import WidgetKit
import SwiftUI

@main
struct ScheduleWidgetBundle: WidgetBundle {
    var body: some Widget {
        ScheduleWidget()
        DayScheduleWidget()
        TimesWidget()
    }
}
