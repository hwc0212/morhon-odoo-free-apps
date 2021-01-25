# -*- coding: utf-8 -*-
import logging
import smtplib
from odoo import _, api, fields, models, tools
from odoo.addons.base.models.ir_mail_server import MailDeliveryException
from odoo.exceptions import UserError
from odoo.tools import ustr
from ssl import SSLError
from socket import gaierror, timeout
import idna

_logger = logging.getLogger(__name__)

class Message(models.Model):
    _inherit = 'mail.message'

    @api.model_create_multi
    def create(self, values_list):
        self.env['ir.config_parameter'].set_param("mail.catchall.domain", self.env.company.company_domain)
        return super(Message, self).create(values_list)


class IrMailServer(models.Model):
    _inherit = "ir.mail_server"

    default_company = fields.Many2one('res.company', string="Company")

    _sql_constraints = [
        ('smtp_company_uniq', 'unique(default_company)',
         'That company already has a default server.')
    ]

    @api.model
    def send_email(self, message, mail_server_id=None,
                   smtp_server=None, smtp_port=None, smtp_user=None,
                   smtp_password=None, smtp_encryption=None,
                   smtp_debug=False, smtp_session=None):

        active_company_id = self.env.company
        server_id = self.env['ir.mail_server'].search([('default_company', '=', active_company_id.id)], limit=1)
        email_from_user = message['From'].split(' ', 1)[0] or ''
        from_value = email_from_user + ' <' + server_id.smtp_user + '>'

        if server_id and server_id[0]:
            if 'Return-Path' in message:
                message.replace_header('Return-Path', server_id.smtp_user)
                message.replace_header('From', from_value)
        return super(IrMailServer, self).send_email(message, mail_server_id,
                                                    smtp_server, smtp_port,
                                                    smtp_user, smtp_password,
                                                    smtp_encryption,
                                                    smtp_debug, smtp_session)

    def test_smtp_connection(self):
        for server in self:
            smtp = False
            try:
                smtp = self.connect(mail_server_id=server.id)
                # simulate sending an email from current user's address - without sending it!
                email_from, email_to = self.smtp_user, 'noreply@odoo.com'
                if not email_from:
                    raise UserError(_('Please configure an email on the current user to simulate '
                                      'sending an email message via this outgoing server'))
                # Testing the MAIL FROM step should detect sender filter problems
                (code, repl) = smtp.mail(email_from)
                if code != 250:
                    raise UserError(_('The server refused the sender address (%(email_from)s) '
                                      'with error %(repl)s') % locals())
                # Testing the RCPT TO step should detect most relaying problems
                (code, repl) = smtp.rcpt(email_to)
                if code not in (250, 251):
                    raise UserError(_('The server refused the test recipient (%(email_to)s) '
                                      'with error %(repl)s') % locals())
                # Beginning the DATA step should detect some deferred rejections
                # Can't use self.data() as it would actually send the mail!
                smtp.putcmd("data")
                (code, repl) = smtp.getreply()
                if code != 354:
                    raise UserError(_('The server refused the test connection '
                                      'with error %(repl)s') % locals())
            except UserError as e:
                # let UserErrors (messages) bubble up
                raise e
            except (UnicodeError, idna.core.InvalidCodepoint) as e:
                raise UserError(_("Invalid server name !\n %s", ustr(e)))
            except (gaierror, timeout) as e:
                raise UserError(_("No response received. Check server address and port number.\n %s", ustr(e)))
            except smtplib.SMTPServerDisconnected as e:
                raise UserError(_(
                    "The server has closed the connection unexpectedly. Check configuration served on this port number.\n %s",
                    ustr(e.strerror)))
            except smtplib.SMTPResponseException as e:
                raise UserError(_("Server replied with following exception:\n %s", ustr(e.smtp_error)))
            except smtplib.SMTPException as e:
                raise UserError(_("An SMTP exception occurred. Check port number and connection security type.\n %s",
                                  ustr(e.smtp_error)))
            except SSLError as e:
                raise UserError(_("An SSL exception occurred. Check connection security type.\n %s", ustr(e)))
            except Exception as e:
                raise UserError(_("Connection Test Failed! Here is what we got instead:\n %s", ustr(e)))
            finally:
                try:
                    if smtp:
                        smtp.close()
                except Exception:
                    # ignored, just a consequence of the previous exception
                    pass

        title = _("Connection Test Succeeded!")
        message = _("Everything seems properly set up!")
        return {
            'type': 'ir.actions.client',
            'tag': 'display_notification',
            'params': {
                'title': title,
                'message': message,
                'sticky': False,
            }
        }


class MailMail(models.Model):
    _inherit = "mail.mail"

    def send(self, auto_commit=False, raise_exception=False):
        for server_id, batch_ids in self._split_by_server():
            smtp_session = None


            # active_company_id = self.env['res.users'].browse(self._context.get('uid') or self.env.user).company_id
            active_company_id = self.env.company
            company_server_id = self.env['ir.mail_server'].search([('default_company', '=', active_company_id.id)],limit=1)
            server_id = company_server_id and company_server_id.id or server_id
            try:
                smtp_session = self.env['ir.mail_server'].connect(mail_server_id=server_id)
            except Exception as exc:
                if raise_exception:
                    # To be consistent and backward compatible with mail_mail.send() raised
                    # exceptions, it is encapsulated into an Odoo MailDeliveryException
                    raise MailDeliveryException(_('Unable to connect to SMTP Server'), exc)
                else:
                    batch = self.browse(batch_ids)
                    batch.write({'state': 'exception', 'failure_reason': exc})
                    batch._postprocess_sent_message(success_pids=[], failure_type="SMTP")
            else:
                self.browse(batch_ids)._send(
                    auto_commit=auto_commit,
                    raise_exception=raise_exception,
                    smtp_session=smtp_session)
                _logger.info(
                    'Sent batch %s emails via mail server ID #%s',
                    len(batch_ids), server_id)
            finally:
                if smtp_session:
                    smtp_session.quit()


class MailThread(models.AbstractModel):
    _inherit = 'mail.thread'
    
    @api.model
    def _message_route_process(self, message, message_dict, routes):
        self = self.with_context(attachments_mime_plainxml=True) # import XML attachments as text
        # postpone setting message_dict.partner_ids after message_post, to avoid double notifications
        original_partner_ids = message_dict.pop('partner_ids', [])
        thread_id = False
        for model, thread_id, custom_values, user_id, alias in routes or ():
            subtype_id = False
            related_user = self.env['res.users'].browse(user_id)
            Model = self.env[model].with_context(mail_create_nosubscribe=True, mail_create_nolog=True)
            if not (thread_id and hasattr(Model, 'message_update') or hasattr(Model, 'message_new')):
                raise ValueError(
                    "Undeliverable mail with Message-Id %s, model %s does not accept incoming emails" %
                    (message_dict['message_id'], model)
                )

            # disabled subscriptions during message_new/update to avoid having the system user running the
            # email gateway become a follower of all inbound messages
            ModelCtx = Model.with_user(related_user).sudo()
            if thread_id and hasattr(ModelCtx, 'message_update'):
                thread = ModelCtx.browse(thread_id)
                thread.message_update(message_dict)
            else:
                # if a new thread is created, parent is irrelevant
                message_dict.pop('parent_id', None)
                thread = ModelCtx.message_new(message_dict, custom_values)


                company_id = self.env['res.company'].search([('company_domain', '=', alias.alias_domain)])
                thread.sudo().write({'company_id': company_id.id})

                
                thread_id = thread.id
                subtype_id = thread._creation_subtype().id

            # replies to internal message are considered as notes, but parent message
            # author is added in recipients to ensure he is notified of a private answer
            parent_message = False
            if message_dict.get('parent_id'):
                parent_message = self.env['mail.message'].sudo().browse(message_dict['parent_id'])
            partner_ids = []
            if not subtype_id:
                if message_dict.get('is_internal'):
                    subtype_id = self.env['ir.model.data'].xmlid_to_res_id('mail.mt_note')
                    if parent_message and parent_message.author_id:
                        partner_ids = [parent_message.author_id.id]
                else:
                    subtype_id = self.env['ir.model.data'].xmlid_to_res_id('mail.mt_comment')

            post_params = dict(subtype_id=subtype_id, partner_ids=partner_ids, **message_dict)
            # remove computational values not stored on mail.message and avoid warnings when creating it
            for x in ('from', 'to', 'cc', 'recipients', 'references', 'in_reply_to', 'bounced_email', 'bounced_message', 'bounced_msg_id', 'bounced_partner'):
                post_params.pop(x, None)
            new_msg = False
            if thread._name == 'mail.thread':  # message with parent_id not linked to record
                new_msg = thread.message_notify(**post_params)
            else:
                # parsing should find an author independently of user running mail gateway, and ensure it is not odoobot
                partner_from_found = message_dict.get('author_id') and message_dict['author_id'] != self.env['ir.model.data'].xmlid_to_res_id('base.partner_root')
                thread = thread.with_context(mail_create_nosubscribe=not partner_from_found)
                new_msg = thread.message_post(**post_params)

            if new_msg and original_partner_ids:
                # postponed after message_post, because this is an external message and we don't want to create
                # duplicate emails due to notifications
                new_msg.write({'partner_ids': original_partner_ids})
        return thread_id
        

