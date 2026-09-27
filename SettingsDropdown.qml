import QtQuick
import qs.Ui

// The shell's Dropdown writes its own `value` when an option is picked, and in
// QML an assignment discards whatever binding the caller gave that property.
// After one pick, a dropdown bound straight to the config kept showing its own
// choice while the config moved on — a hand edit, or the service's own write,
// never reached the label again. Binding `source` instead, and copying it
// across on every change, keeps the label honest for the life of the panel.
Dropdown {
  id: root

  property string source: ""

  value: source
  onSourceChanged: if (value !== source) value = source
}
