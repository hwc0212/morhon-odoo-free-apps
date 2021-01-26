# -*- coding: utf-8 -*-
from odoo import fields, models

class Company(models.Model):

    _inherit = 'res.company'

    company_domain = fields.Char(string="Domain", store=True)

