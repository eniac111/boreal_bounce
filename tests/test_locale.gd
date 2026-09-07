extends TestCase


func test_po_files_load_as_translations() -> void:
	var tr_fr = load("res://assets/locale/fr.po")
	assert_true(tr_fr is Translation, "fr.po loads as a Translation resource")
	if tr_fr is Translation:
		assert_eq(tr_fr.locale, "fr")
		assert_true(tr_fr.get_message_count() > 50, "fr has %d messages" % tr_fr.get_message_count())
	# the transcoded ISO-8859-1 files must load too and keep their accents
	var tr_it = load("res://assets/locale/it.po")
	assert_true(tr_it is Translation, "it.po loads")


func test_messages_keep_placeholders_and_accents() -> void:
	var tr_fr: Translation = load("res://assets/locale/fr.po")
	assert_eq(tr_fr.get_message("Level %s"), "Niveau %s")
	var tr_it: Translation = load("res://assets/locale/it.po")
	var msg := String(tr_it.get_message("Player 1; turn left?"))
	assert_true(msg != "" and msg != "Player 1; turn left?", "it.po has a translation: " + msg)


func test_locale_switch_translates() -> void:
	var before := TranslationServer.get_locale()
	var tr_fr: Translation = load("res://assets/locale/fr.po")
	TranslationServer.add_translation(tr_fr)
	TranslationServer.set_locale("fr")
	var t := TranslationServer.translate("Level %s")
	TranslationServer.set_locale(before)
	TranslationServer.remove_translation(tr_fr)
	assert_eq(t, "Niveau %s", "tr('Level %s') in fr")
