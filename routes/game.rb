# frozen_string_literal: true

require_relative '../lib/engine'

class Api
  TURN_CHANNEL = '/turn'

  hash_routes :api do |hr|
    hr.on 'game' do |r|
      # '/api/game/<game_id>/*'
      r.on Integer do |id|
        halt(404, 'Game does not exist') unless (game = Game[id])

        # '/api/game/<game_id>/'
        r.is do
          game.to_h(include_actions: true)
        end

        # POST '/api/game/<game_id>'
        r.post do
          not_authorized! unless user

          users = game.ordered_players

          # POST '/api/game/<game_id>/join'
          r.is 'join' do
            halt(400, 'Cannot join game because it is full') if users.size >= game.max_players

            GameUser.create(game: game, user: user)
            game.players(reload: true)
            return_and_notify(game)
          end

          not_authorized! unless users.any? { |u| u.id == user.id }

          r.is 'leave' do
            game.remove_player(user)
            return_and_notify(game)
          end

          # POST '/api/game/<game_id>/action'
          r.is 'action' do
            acting, action = nil

            DB.with_advisory_lock(:action_lock, game.id) do
              if game.settings['pin']
                action_id = r.params['id']
                action = r.params
                meta = action.delete('meta')
                halt(400, 'Game missing metadata') unless meta
                halt(400, 'Game out of sync') unless actions_h(game).size + 1 == action_id

                Action.create(
                  game: game,
                  user: user,
                  action_id: action_id,
                  turn: meta['turn'],
                  round: meta['round'],
                  action: action,
                )

                active_players = meta['active_players']
                acting = users.select { |u| active_players.include?(u.name) }

                game.round = meta['round']
                game.turn = meta['turn']
                game.acting = acting.map(&:id)

                game.result = meta['game_result']
                game.status = meta['game_status']

                game.save
              else
                engine = Engine::GAMES_BY_TITLE[game.title].new(
                  users.map(&:name),
                  actions: actions_h(game),
                )

                action_id = r.params['id']
                halt(400, 'Game out of sync') unless engine.actions.size + 1 == action_id

                engine = engine.process_action(r.params)
                action = engine.actions.last.to_h

                Action.create(
                  game: game,
                  user: user,
                  action_id: action_id,
                  turn: engine.turn,
                  round: engine.round.name,
                  action: action,
                )

                active_players = engine.active_players.map(&:name)
                acting = users.select { |u| active_players.include?(u.name) }
                set_game_state(game, acting, engine)
              end
            end

            type, user_ids =
              if action['type'] == 'message'
                pinged = users.select do |user|
                  action['message'].include?("@#{user.name}")
                end
                ['Received Message', pinged.map(&:id)]
              else
                ['Your Turn', acting.map(&:id)]
              end

            if user_ids.any?
              MessageBus.publish(
                TURN_CHANNEL,
                user_ids: user_ids,
                game_id: game.id,
                game_url: "#{r.base_url}/game/#{game.id}",
                type: type,
              )
            end

            publish("/game/#{game.id}", **action)
            return_and_notify(game)
          end

          not_authorized! unless game.user_id == user.id

          # POST '/api/game/<game_id>/delete
          r.is 'delete' do
            game_h = game.to_h.merge(deleted: true)
            game.destroy
            publish('/games', **game_h)
            game_h
          end

          # POST '/api/game/<game_id>/start
          r.is 'start' do
            halt(400, 'Cannot play 1 player') if game.players.size < 2

            game.update(
              status: 'active',
              acting: [users.first.id],
            )
            return_and_notify(game)
          end

          # POST '/api/game/<game_id>/kick
          r.is 'kick' do
            game.remove_player(r.params['id'])
            return_and_notify(game)
          end
        end
      end

      r.get do
        { games: Game.home_games(user, **r.params).map(&:to_h) }
      end

      # POST '/api/game[/*]'
      r.post do
        not_authorized! unless user

        # POST '/api/game'
        r.is do
          title = r['title']

          params = {
            user: user,
            description: r['description'],
            max_players: r['max_players'],
            settings: { seed: Random.new_seed },
            title: title,
            round: Engine::GAMES_BY_TITLE[title].new([]).round.name,
          }

          game = Game.create(params)
          GameUser.create(game: game, user: user)
          return_and_notify(game)
        end
      end
    end
  end

  def actions_h(game)
    game.actions(reload: true).map(&:to_h)
  end

  def return_and_notify(game)
    game_h = game.to_h
    publish('/games', **game_h)
    game_h
  end

  def set_game_state(game, acting, engine)
    game.round = engine.round.name
    game.turn = engine.turn
    game.acting = acting.map(&:id)

    if engine.finished
      game.result = engine.result
      game.status = 'finished'
    else
      game.result = {}
      game.status = 'active'
    end

    game.save
  end

  MessageBus.subscribe TURN_CHANNEL do |msg|
    data = msg.data

    DB.with_advisory_lock(:turn_lock, data['game_id']) do
      users = User.where(id: data['user_ids']).all
      game = Game[data['game_id']]
      minute_ago = Time.now - 60

      connected = Session
        .where(user: users)
        .group_by(:user_id)
        .having { max(updated_at) > minute_ago }
        .select(:user_id)
        .all
        .map(&:user_id)

      users = users.reject do |user|
        email_sent = user.settings['email_sent'] || 0

        connected.include?(user.id) ||
          user.settings['notifications'] == false ||
          email_sent > minute_ago.to_i
      end

      next if users.empty?

      html = ASSETS.html(
        'assets/app/mail/turn.rb',
        game_data: game.to_h(include_actions: true),
        game_url: data['game_url'],
      )

      users.each do |user|
        user.settings['email_sent'] = Time.now.to_i
        user.save
        Mail.send(user, "18xx.games Game: #{game.title} - #{game.id} - #{data['type']}", html)
      end
    end
  end
end
