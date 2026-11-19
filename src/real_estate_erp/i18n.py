"""Arabic (default, right-to-left) and English (left-to-right) interface text and number formatting.

Numbers use Western digits with thousands separators in both languages; amounts are in SAR.
"""

from datetime import datetime
from decimal import Decimal

from markupsafe import Markup, escape

LANGUAGES = ("ar", "en")
DEFAULT_LANGUAGE = "ar"
DIRECTION = {"ar": "rtl", "en": "ltr"}

TEXT: dict[str, dict[str, str]] = {
    "ar": {
        "app_name": "نظام إدارة العقارات",
        "app_tagline": "إدارة الأراضي والاستثمار العقاري",
        "dev_data": "بيانات تطوير",
        "dev_data_note": "هذه نسخة تجريبية تعمل على بيانات تطوير فقط، وجميع العمليات المالية للعرض فقط.",
        "read_only": "للعرض فقط",
        "language": "اللغة",
        "switch_language": "English",
        "menu": "القائمة",
        # navigation
        "nav_main": "الرئيسية",
        "nav_dashboard": "لوحة المعلومات",
        "nav_operations": "العمليات",
        "nav_lands": "الأراضي",
        "nav_investors": "المستثمرون",
        "nav_portfolios": "المحافظ",
        "nav_finance": "المالية",
        "nav_accounting": "المحاسبة",
        "nav_coming": "قريبًا",
        "nav_deals": "الصفقات",
        "nav_distributions": "توزيعات الأرباح",
        "nav_reports": "التقارير",
        "nav_admin": "الإدارة",
        "nav_employees": "الموظفون",
        "soon": "قريبًا",
        # login
        "login_title": "تسجيل الدخول",
        "login_subtitle": "دخول المسؤول",
        "email": "البريد الإلكتروني",
        "password": "كلمة المرور",
        "sign_in": "دخول",
        "sign_out": "تسجيل الخروج",
        "login_invalid": "البريد الإلكتروني أو كلمة المرور غير صحيحة. بعد 5 محاولات خاطئة يُقفل الحساب لمدة 15 دقيقة.",
        "login_not_admin": "هذا الإصدار مخصص لحساب المسؤول فقط.",
        "login_expired": "انتهت الجلسة. يرجى تسجيل الدخول مرة أخرى.",
        "login_form_expired": "انتهت صلاحية النموذج. يرجى المحاولة مرة أخرى.",
        "login_secure_note": "اتصال آمن · كلمات المرور مشفرة بخوارزمية Argon2id",
        "login_hero_title": "إدارة عقارية بمعايير مؤسسية",
        "login_hero_text": "تتبع الأراضي والتكاليف وضريبة الشراء والدلالة في مكان واحد، مع صلاحيات دقيقة واعتماد بمبدأ الأربع أعين وسجل تدقيق كامل.",
        # dashboard
        "dashboard_title": "لوحة المعلومات",
        "welcome": "مرحبًا",
        "dashboard_intro": "نظرة عامة على أراضي المكتب وتكاليف الاستحواذ.",
        "card_lands": "عدد الأراضي",
        "card_total_area": "إجمالي المساحة",
        "card_purchase_price": "إجمالي سعر الشراء",
        "card_purchase_tax": "ضريبة الشراء ⁦(5%)⁩",
        "card_dalalah": "دلالة شراء الأرض ⁦(2.5%)⁩",
        "card_total_cost": "إجمالي تكلفة الاستحواذ",
        "lands_overview": "الأراضي",
        "view_all": "عرض الكل",
        "status_breakdown": "حالة الأراضي",
        "recent_activity": "آخر النشاطات",
        "no_activity": "لا توجد نشاطات بعد.",
        "preview_note": "الضريبة والدلالة معاينة محسوبة وفق قواعد النظام؛ لم تُسجَّل أي عملية شراء.",
        # lands
        "lands_title": "الأراضي",
        "lands_intro": "أراضي التطوير الحالية مع ضريبة الشراء والدلالة وإجمالي تكلفة الاستحواذ.",
        "land": "الأرض",
        "city": "المدينة",
        "plan_number": "رقم المخطط",
        "land_number": "رقم القطعة",
        "area": "المساحة",
        "street_width": "عرض الشارع",
        "status": "الحالة",
        "purchase_price": "سعر الشراء",
        "purchase_tax": "ضريبة الشراء",
        "dalalah": "دلالة شراء الأرض",
        "total_cost": "إجمالي تكلفة الاستحواذ",
        "details": "التفاصيل",
        "land_details": "تفاصيل الأرض",
        "back_to_lands": "العودة إلى الأراضي",
        "acquisition_breakdown": "تفصيل تكلفة الاستحواذ",
        "purchase_tax_rate": "⁦5%⁩ من سعر الشراء — الضريبة الوحيدة في النظام",
        "dalalah_rate": "⁦2.5%⁩ من سعر الشراء — عمولة وليست ضريبة",
        "charges_on_purchase_only": "تُحتسب الضريبة والدلالة عند الشراء فقط، ولا تُحتسب عند البيع.",
        "purchase_recorded": "الشراء",
        "recorded": "مسجَّل",
        "not_recorded": "معاينة — لم يُسجَّل بعد",
        "land_summary": "بيانات الأرض",
        "totals": "الإجمالي",
        "no_lands": "لا توجد أراضٍ بعد.",
        # modules
        "investors_title": "المستثمرون",
        "investors_intro": "المستثمرون المباشرون وأعضاء المحافظ المشتركة.",
        "portfolios_title": "المحافظ",
        "portfolios_intro": "المحافظ المشتركة التي يجمع فيها المستثمرون رأس المال.",
        "accounting_title": "المحاسبة",
        "accounting_intro": "دليل الحسابات والقيود اليومية وفق مبدأ الأربع أعين.",
        "module_soon_title": "هذه الوحدة قيد الإعداد",
        "module_soon_text": "ستُضاف شاشات الإدخال والاعتماد في مرحلة لاحقة. يعرض هذا الإصدار البيانات فقط.",
        "empty_dev": "لا توجد سجلات في بيانات التطوير بعد.",
        "active_investors": "المستثمرون النشطون",
        "active_portfolios": "المحافظ النشطة",
        "active_deals": "الصفقات",
        "ledger_accounts": "الحسابات",
        "journal_posted": "قيود مُرحَّلة",
        "journal_draft": "قيود مسودة",
        "land_purchases": "عمليات شراء مسجلة",
        "completed_sales": "عمليات بيع مكتملة",
        "controls_title": "الضوابط المطبقة",
        "control_four_eyes": "مبدأ الأربع أعين: من يُعدّ القيد لا يمكنه ترحيله أو اعتماده.",
        "control_one_employee": "موظف واحد لكل معاملة في قاعدة البيانات.",
        "control_audit": "سجل تدقيق دائم لا يمكن تعديله أو حذفه.",
        "control_tax": "الضريبة الوحيدة: ضريبة شراء الأرض ⁦5%⁩.",
        # values
        "sqm": "م²",
        "meters": "م",
        "currency": "ر.س",
        "role_admin": "مدير النظام",
        "role_accountant": "محاسب",
        "role_data_entry": "مُدخل بيانات",
        "role_viewer": "مُطّلع",
        "status_prospective": "قيد الدراسة",
        "status_available": "متاحة",
        "status_listed": "معروضة للبيع",
        "status_under_contract": "تحت التعاقد",
        "status_partially_sold": "مباعة جزئيًا",
        "status_sold": "مباعة",
        "status_cancelled": "ملغاة",
        "not_found_title": "الصفحة غير موجودة",
        "not_found_text": "تعذر العثور على الصفحة المطلوبة.",
        "back_home": "العودة إلى لوحة المعلومات",
    },
    "en": {
        "app_name": "Real Estate ERP",
        "app_tagline": "Land & real estate investment management",
        "dev_data": "Development data",
        "dev_data_note": "This MVP runs on development data only. All financial operations are read-only.",
        "read_only": "Read-only",
        "language": "Language",
        "switch_language": "العربية",
        "menu": "Menu",
        "nav_main": "Main",
        "nav_dashboard": "Dashboard",
        "nav_operations": "Operations",
        "nav_lands": "Lands",
        "nav_investors": "Investors",
        "nav_portfolios": "Portfolios",
        "nav_finance": "Finance",
        "nav_accounting": "Accounting",
        "nav_coming": "Coming soon",
        "nav_deals": "Deals",
        "nav_distributions": "Distributions",
        "nav_reports": "Reports",
        "nav_admin": "Administration",
        "nav_employees": "Employees",
        "soon": "Soon",
        "login_title": "Sign in",
        "login_subtitle": "Administrator access",
        "email": "Email",
        "password": "Password",
        "sign_in": "Sign in",
        "sign_out": "Sign out",
        "login_invalid": "Incorrect email or password. After 5 failed attempts the account is locked for 15 minutes.",
        "login_not_admin": "This version is for the administrator account only.",
        "login_expired": "Your session has ended. Please sign in again.",
        "login_form_expired": "The form expired. Please try again.",
        "login_secure_note": "Secure connection · passwords hashed with Argon2id",
        "login_hero_title": "Institutional-grade real estate management",
        "login_hero_text": "Track lands, acquisition costs, purchase tax and Dalalah in one place — with fine-grained permissions, four-eyes approvals and a complete audit trail.",
        "dashboard_title": "Dashboard",
        "welcome": "Welcome",
        "dashboard_intro": "An overview of the office's lands and acquisition costs.",
        "card_lands": "Lands",
        "card_total_area": "Total area",
        "card_purchase_price": "Total purchase price",
        "card_purchase_tax": "Purchase tax (5%)",
        "card_dalalah": "Land Purchase Brokerage Commission (Dalalah) (2.5%)",
        "card_total_cost": "Total acquisition cost",
        "lands_overview": "Lands",
        "view_all": "View all",
        "status_breakdown": "Land status",
        "recent_activity": "Recent activity",
        "no_activity": "No activity yet.",
        "preview_note": "Tax and Dalalah are a preview calculated by the system rules; no purchase has been recorded.",
        "lands_title": "Lands",
        "lands_intro": "Current development lands with purchase tax, Dalalah and total acquisition cost.",
        "land": "Land",
        "city": "City",
        "plan_number": "Plan number",
        "land_number": "Plot number",
        "area": "Area",
        "street_width": "Street width",
        "status": "Status",
        "purchase_price": "Purchase price",
        "purchase_tax": "Purchase tax",
        "dalalah": "Land Purchase Brokerage Commission (Dalalah)",
        "total_cost": "Total acquisition cost",
        "details": "Details",
        "land_details": "Land details",
        "back_to_lands": "Back to lands",
        "acquisition_breakdown": "Acquisition cost breakdown",
        "purchase_tax_rate": "5% of the purchase price — the only tax in the system",
        "dalalah_rate": "2.5% of the purchase price — a commission, not a tax",
        "charges_on_purchase_only": "Tax and Dalalah apply on purchase only, never on a sale.",
        "purchase_recorded": "Purchase",
        "recorded": "Recorded",
        "not_recorded": "Preview — not yet recorded",
        "land_summary": "Land information",
        "totals": "Total",
        "no_lands": "No lands yet.",
        "investors_title": "Investors",
        "investors_intro": "Direct investors and members of shared portfolios.",
        "portfolios_title": "Portfolios",
        "portfolios_intro": "Shared portfolios through which investors pool capital.",
        "accounting_title": "Accounting",
        "accounting_intro": "Chart of accounts and journal entries under the four-eyes rule.",
        "module_soon_title": "This module is being prepared",
        "module_soon_text": "Data entry and approval screens come in a later phase. This version is read-only.",
        "empty_dev": "No records in the development data yet.",
        "active_investors": "Active investors",
        "active_portfolios": "Active portfolios",
        "active_deals": "Deals",
        "ledger_accounts": "Ledger accounts",
        "journal_posted": "Posted entries",
        "journal_draft": "Draft entries",
        "land_purchases": "Recorded purchases",
        "completed_sales": "Completed sales",
        "controls_title": "Controls in place",
        "control_four_eyes": "Four-eyes rule: whoever prepares an entry can never post or approve it.",
        "control_one_employee": "One employee per database transaction.",
        "control_audit": "Permanent audit trail that cannot be edited or deleted.",
        "control_tax": "The only tax: 5% land purchase tax.",
        "sqm": "m²",
        "meters": "m",
        "currency": "SAR",
        "role_admin": "Administrator",
        "role_accountant": "Accountant",
        "role_data_entry": "Data Entry",
        "role_viewer": "Viewer",
        "status_prospective": "Prospective",
        "status_available": "Available",
        "status_listed": "Listed",
        "status_under_contract": "Under contract",
        "status_partially_sold": "Partially sold",
        "status_sold": "Sold",
        "status_cancelled": "Cancelled",
        "not_found_title": "Page not found",
        "not_found_text": "The page you asked for could not be found.",
        "back_home": "Back to dashboard",
    },
}

# Audit actions and record types shown in "Recent activity".
ACTIONS = {
    "ar": {"create": "إنشاء", "update": "تعديل", "delete": "حذف", "post": "ترحيل", "reverse": "عكس", "approve": "اعتماد",
           "pay": "صرف", "cancel": "إلغاء", "void": "إبطال", "settle": "تسوية", "close": "إغلاق", "deactivate": "تعطيل",
           "reactivate": "إعادة تفعيل", "role_change": "تغيير الصلاحية", "session_open": "تسجيل دخول",
           "session_revoke": "تسجيل خروج", "credential_create": "تعيين كلمة المرور", "credential_update": "تحديث بيانات الدخول",
           "status_change": "تغيير الحالة", "disable": "تعطيل"},
    "en": {"create": "Created", "update": "Updated", "delete": "Deleted", "post": "Posted", "reverse": "Reversed",
           "approve": "Approved", "pay": "Paid", "cancel": "Cancelled", "void": "Voided", "settle": "Settled",
           "close": "Closed", "deactivate": "Deactivated", "reactivate": "Reactivated", "role_change": "Role changed",
           "session_open": "Signed in", "session_revoke": "Signed out", "credential_create": "Password set",
           "credential_update": "Sign-in record updated", "status_change": "Status changed", "disable": "Disabled"},
}
ENTITIES = {
    "ar": {"lands": "أرض", "app_users": "موظف", "user_sessions": "جلسة", "user_credentials": "بيانات دخول",
           "investors": "مستثمر", "portfolios": "محفظة", "deals": "صفقة", "journal_entries": "قيد يومية",
           "cities": "مدينة", "city_aliases": "اسم مدينة"},
    "en": {"lands": "Land", "app_users": "Employee", "user_sessions": "Session", "user_credentials": "Credentials",
           "investors": "Investor", "portfolios": "Portfolio", "deals": "Deal", "journal_entries": "Journal entry",
           "cities": "City", "city_aliases": "City spelling"},
}


def language(value: str | None) -> str:
    return value if value in LANGUAGES else DEFAULT_LANGUAGE


def translator(lang: str):
    table = TEXT[lang]

    def t(key: str) -> str:
        return table.get(key, key)

    return t


def _number(value, decimals: int) -> str:
    return f"{Decimal(value):,.{decimals}f}"


def money(value, lang: str) -> Markup:
    """SAR amount with Western digits, isolated so it reads correctly inside right-to-left text."""
    number = escape(_number(value, 2))
    if lang == "ar":
        return Markup(f'<span class="val"><bdi class="num">{number}</bdi> <span class="cur">ر.س</span></span>')
    return Markup(f'<span class="val"><span class="cur">SAR</span> <bdi class="num">{number}</bdi></span>')


def quantity(value, unit_key: str, lang: str) -> Markup:
    if value is None:
        return Markup("—")
    v = Decimal(value)
    decimals = 0 if v == v.to_integral() else 2
    return Markup(f'<span class="val"><bdi class="num">{escape(_number(v, decimals))}</bdi> {escape(TEXT[lang][unit_key])}</span>')


def count(value) -> Markup:
    return Markup(f'<bdi class="num">{escape(_number(value, 0))}</bdi>')


def timestamp(value: datetime, lang: str) -> Markup:
    return Markup(f'<bdi class="num">{escape(value.strftime("%Y-%m-%d %H:%M"))}</bdi>')


def action_label(action: str, lang: str) -> str:
    return ACTIONS[lang].get(action, action)


def entity_label(entity: str, lang: str) -> str:
    return ENTITIES[lang].get(entity, entity)
