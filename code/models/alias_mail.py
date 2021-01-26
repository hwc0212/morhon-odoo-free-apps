# -*- coding: utf-8 -*-

import ast

import logging

import re
import socket

from email.message import EmailMessage


from odoo import _, api, fields, models, tools
from odoo.tools import remove_accents


_logger = logging.getLogger(__name__)



class MailThreadInherit(models.AbstractModel):
    _inherit = 'mail.thread'

    @api.model
    def message_route(self, message, message_dict, model=None, thread_id=None, custom_values=None):
        if not isinstance(message, EmailMessage):
            raise TypeError('message must be an email.message.EmailMessage at this point')
        catchall_alias = self.env['ir.config_parameter'].sudo().get_param("mail.catchall.alias")
        bounce_alias = self.env['ir.config_parameter'].sudo().get_param("mail.bounce.alias")
        fallback_model = model

        # get email.message.Message variables for future processing
        local_hostname = socket.gethostname()
        message_id = message_dict['message_id']

        # compute references to find if message is a reply to an existing thread
        thread_references = message_dict['references'] or message_dict['in_reply_to']
        msg_references = [ref for ref in tools.mail_header_msgid_re.findall(thread_references) if 'reply_to' not in ref]
        mail_messages = self.env['mail.message'].sudo().search([('message_id', 'in', msg_references)], limit=1,
                                                               order='id desc, message_id')
        is_a_reply = bool(mail_messages)
        reply_model, reply_thread_id = mail_messages.model, mail_messages.res_id

        # author and recipients
        email_from = message_dict['email_from']
        email_from_localpart = (tools.email_split(email_from) or [''])[0].split('@', 1)[0].lower()
        email_to = message_dict['to']
        email_to_localparts = [
            e.split('@', 1)[0].lower()
            for e in (tools.email_split(email_to) or [''])
        ]
        # Delivered-To is a safe bet in most modern MTAs, but we have to fallback on To + Cc values
        # for all the odd MTAs out there, as there is no standard header for the envelope's `rcpt_to` value.
        rcpt_tos_localparts = [
            e.split('@')[0].lower()
            for e in tools.email_split(message_dict['recipients'])
        ]
        rcpt_tos_valid_localparts = [to for to in rcpt_tos_localparts]

        email_to_alias_domain_list = [
            e.split('@')[1].lower()
            for e in tools.email_split(message_dict['recipients'])
        ]
        #         email_to_alias_domain = email_to_localpart_after.split('>')[0]

        # 0. Handle bounce: verify whether this is a bounced email and use it to collect bounce data and update notifications for customers
        #    Bounce regex: typical form of bounce is bounce_alias+128-crm.lead-34@domain
        #       group(1) = the mail ID; group(2) = the model (if any); group(3) = the record ID
        #    Bounce message (not alias)
        #       See http://datatracker.ietf.org/doc/rfc3462/?include_text=1
        #        As all MTA does not respect this RFC (googlemail is one of them),
        #       we also need to verify if the message come from "mailer-daemon"
        #    If not a bounce: reset bounce information
        if bounce_alias and any(email.startswith(bounce_alias) for email in email_to_localparts):
            bounce_re = re.compile("%s\+(\d+)-?([\w.]+)?-?(\d+)?" % re.escape(bounce_alias), re.UNICODE)
            bounce_match = bounce_re.search(email_to)
            if bounce_match:
                self._routing_handle_bounce(message, message_dict)
                return []
        if message.get_content_type() == 'multipart/report' or email_from_localpart == 'mailer-daemon':
            self._routing_handle_bounce(message, message_dict)
            return []
        self._routing_reset_bounce(message, message_dict)

        # 1. Handle reply
        #    if destination = alias with different model -> consider it is a forward and not a reply
        #    if destination = alias with same model -> check contact settings as they still apply
        if reply_model and reply_thread_id:
            other_model_aliases = self.env['mail.alias'].search([
                '&', '&',
                ('alias_name', '!=', False),
                ('alias_name', 'in', email_to_localparts),
                ('alias_model_id.model', '!=', reply_model),
            ])
            if other_model_aliases:
                is_a_reply = False
                rcpt_tos_valid_localparts = [to for to in rcpt_tos_valid_localparts if
                                             to in other_model_aliases.mapped('alias_name')]

        if is_a_reply:
            dest_aliases = self.env['mail.alias'].search([
                ('alias_name', 'in', rcpt_tos_localparts),
                ('alias_model_id.model', '=', reply_model)
            ], limit=1)

            user_id = self._mail_find_user_for_gateway(email_from, alias=dest_aliases).id or self._uid
            route = self._routing_check_route(
                message, message_dict,
                (reply_model, reply_thread_id, custom_values, user_id, dest_aliases),
                raise_exception=False)
            if route:
                _logger.info(
                    'Routing mail from %s to %s with Message-Id %s: direct reply to msg: model: %s, thread_id: %s, custom_values: %s, uid: %s',
                    email_from, email_to, message_id, reply_model, reply_thread_id, custom_values, self._uid)
                return [route]
            elif route is False:
                return []

        # 2. Handle new incoming email by checking aliases and applying their settings
        if rcpt_tos_localparts:
            # no route found for a matching reference (or reply), so parent is invalid
            message_dict.pop('parent_id', None)

            # check it does not directly contact catchall
            if catchall_alias and all(email_localpart == catchall_alias for email_localpart in email_to_localparts):
                _logger.info('Routing mail from %s to %s with Message-Id %s: direct write to catchall, bounce',
                             email_from, email_to, message_id)
                body = self.env.ref('mail.mail_bounce_catchall')._render({
                    'message': message,
                }, engine='ir.qweb')
                self._routing_create_bounce_email(email_from, body, message, references=message_id,
                                                  reply_to=self.env.company.email)
                return []

            company_domains = []
            company_ids = self.env['res.company'].search([('company_domain', 'in', email_to_alias_domain_list)])
            for record in company_ids:
                company_domains.append(record.company_domain)

            dest_aliases = False
            if company_domains:
                dest_aliases = self.env['mail.alias'].search(
                    [('alias_domain', 'in', company_domains), ('alias_name', 'in', rcpt_tos_valid_localparts)])

            if dest_aliases:
                routes = []
                for alias in dest_aliases:
                    user_id = self._mail_find_user_for_gateway(email_from, alias=alias).id or self._uid

                    route = (
                    alias.alias_model_id.model, alias.alias_force_thread_id, ast.literal_eval(alias.alias_defaults),
                    user_id, alias)
                    route = self._routing_check_route(message, message_dict, route, raise_exception=True)
                    if route:
                        _logger.info(
                            'Routing mail from %s to %s with Message-Id %s: direct alias match: %r',
                            email_from, email_to, message_id, route)
                        routes.append(route)
                return routes

        # 3. Fallback to the provided parameters, if they work
        if fallback_model:
            # no route found for a matching reference (or reply), so parent is invalid
            message_dict.pop('parent_id', None)
            user_id = self._mail_find_user_for_gateway(email_from).id or self._uid
            route = self._routing_check_route(
                message, message_dict,
                (fallback_model, thread_id, custom_values, user_id, None),
                raise_exception=True)
            if route:
                _logger.info(
                    'Routing mail from %s to %s with Message-Id %s: fallback to model:%s, thread_id:%s, custom_values:%s, uid:%s',
                    email_from, email_to, message_id, fallback_model, thread_id, custom_values, user_id)
                return [route]

        # ValueError if no routes found and if no bounce occured
        raise ValueError(
            'No possible route found for incoming message from %s to %s (Message-Id %s:). '
            'Create an appropriate mail.alias or force the destination model.' %
            (email_from, email_to, message_id)
        )

class Alias(models.Model):
    _inherit = "mail.alias"

    alias_domain = fields.Char('Alias domain', compute=False, default=lambda self: self.env.company.company_domain)

    _sql_constraints = [
        ('alias_unique', 'Check(1=1)', 'Unfortunately this email alias is already used, please choose a unique one')
    ]

    @api.model
    def create(self, vals):
        if vals.get('alias_name'):
            vals['alias_name'] = self._clean_and_check_unique(vals.get('alias_name'))
            #vals['alias_domain'] = self._return_alias_domain(vals.get('alias_domain'))
            vals['alias_domain'] = self._return_alias_domain()
        return super(Alias, self).create(vals)


    def write(self, vals):
        """"Raises UserError if given alias name is already assigned"""
        #f vals.get('alias_name') and self.ids and vals.get('alias_domain'):
        if vals.get('alias_name') and self.ids:
            vals['alias_name'] = self._clean_and_check_unique(vals.get('alias_name'))
            vals['alias_domain'] = self._return_alias_domain()
        return super(Alias, self).write(vals)

    def _clean_and_check_unique(self, name):
        sanitized_name = remove_accents(name).lower().split('@')[0]
        sanitized_name = re.sub(r'[^\w+.]+', '-', sanitized_name)
        return sanitized_name

    def _return_alias_domain(self):
        sanitized_name = self.env.company.company_domain
        return sanitized_name



class ResConfigSettings(models.TransientModel):
    _inherit = 'res.config.settings'

    def _default_alias_domain(self):
        company_domain = self.env.company.company_domain
        self.env['ir.config_parameter'].set_param("mail.catchall.domain", company_domain or '')
        return company_domain


    alias_domain = fields.Char('Alias Domain',
                               help="If you have setup a catch-all email domain redirected to "
                                                    "the Odoo server, enter the domain name here.",
                               default=_default_alias_domain,
                               config_parameter='mail.catchall.domain',
                               compute = '_compute_alias_domain',
                               )

    #
    def _compute_alias_domain(self):
        alias_domain = self._default_alias_domain()
        for record in self:
            record.alias_domain = alias_domain



class Team(models.Model):
    _inherit = "crm.team"

    def _default_alias_domain(self):
        company_domain = self.env.company.company_domain
        return company_domain

    no_alias_domain = fields.Char('No Domain', default="The current company does not have a matching domain name, please set it in res.company!")
    alias_domain = fields.Char('Alias domain', default=_default_alias_domain,compute='_compute_alias_domain')

    def _compute_alias_domain(self):
        alias_domain = self._default_alias_domain()
        for record in self:
            record.alias_domain = alias_domain

class Project(models.Model):
    _inherit = "project.project"

    alias_domain = fields.Char('Alias domain', default=lambda self: self.env.company.company_domain)

class AccountJournal(models.Model):
    _inherit = "account.journal"

    alias_domain = fields.Char('Alias domain', default=lambda self: self.env.company.company_domain)


class Job(models.Model):
    _inherit = "hr.job"

    alias_domain = fields.Char('Alias domain', default=lambda self: self.env.company.company_domain)

