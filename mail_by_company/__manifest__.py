# -*- coding: utf-8 -*-

{
    'name' : 'Mail By Company',
    'version' : '14.0.0.1',
    'author': 'Morhon',
    'company': 'Morhon.com',
    'category': 'sales',
    'website': 'https://www.morhon.com/',
    'summary' : 'Mail By Company',
    'description' : """Geminate comes with a feature to support multiple domain and multi company emailing system.""",
    'depends' : ['base','sale_management','fetchmail','crm','project','mail','account','hr_recruitment'],
    'data' : [
        'security/ir.model.access.csv',
        'views/mail_server_view.xml',
        'views/alias_mail_view.xml',
        'views/res_company_views.xml'
    ],
    'qweb': [],
    "license": "AGPL-3",
    'installable': True,
    'images': ['static/description/email-alias.jpg'],
    'auto_install': False,
    'application': True,
    "price":0,
}

# vim:expandtab:smartindent:tabstop=4:softtabstop=4:shiftwidth=4:
