require "spec_helper"

module WebsocketRails

  describe ".users" do
    before do
      allow(WebsocketRails.users.sync).to receive(:find_remote_user)
      allow(WebsocketRails.users.sync).to receive(:register_remote_user)
      allow(WebsocketRails.users.sync).to receive(:destroy_remote_user)
    end

    it "returns the global instance of UserManager" do
      expect(WebsocketRails.users).to be_a UserManager
    end

    context "when synchronization is enabled" do
      before do
        allow(WebsocketRails).to receive(:synchronize?).and_return(true)
      end

      context "and the user is connected to a different worker" do
        before do
          user_attr = {name: 'test', email: 'test@test.com'}
          allow(WebsocketRails.users.sync).to receive(:find_remote_user).and_return(user_attr)
        end

        it "publishes the event to redis" do
          expect(WebsocketRails.users.sync).to receive(:publish_remote) do |event|
            expect(event.user_id).to eq("remote")
          end

          WebsocketRails.users["remote"].send_message :test, :data
        end

        it "instantiates a user object pulled from redis" do
          remote = WebsocketRails.users["remote"]

          expect(remote.class).to eq(UserManager::RemoteConnection)
          expect(remote.user.class).to eq(User)
          expect(remote.user.name).to eq('test')
          expect(remote.user.persisted?).to eq(true)
        end
      end
    end
  end

  describe UserManager do

    before do
      allow(subject.sync).to receive(:find_remote_user)
      allow(subject.sync).to receive(:register_remote_user)
      allow(subject.sync).to receive(:destroy_remote_user)
    end

    let(:dispatcher) { double('dispatcher').as_null_object }
    let(:connection) do
      connection = double('Connection')
      allow(connection).to receive(:id).and_return(1)
      allow(connection).to receive(:user_identifier).and_return('Juanita')
      allow(connection).to receive(:dispatcher).and_return(dispatcher)
      connection
    end

    describe "#[]=" do
      it "store's a reference to a connection in the user's hash" do
        subject["username"] = connection
        expect(subject.users["username"].connections.first).to eq(connection)
      end

      context "user has no existing connections" do
        it "dispatches websocket_rails.user_connected" do
          connection.dispatcher.stub(:dispatch) do |dispatch_event|
            # Make sure that we add the LocalConnection before the event
            # is dispatched because a consumer could try to immediately send
            # a message to the connecting user
            subject["username"].should be_a UserManager::LocalConnection

            dispatch_event.data[:identifier].should eq("username")
            dispatch_event.is_internal?.should be true
            dispatch_event.name.should eq(:user_connected)
          end

          subject["username"] = connection
        end
      end

      context "user has an existing connection" do
        before do
          subject["username"] = connection
        end

        it "doesn't dispatch websocket_rails.user_connected" do
          connection.dispatcher.should_not_receive(:dispatch)
          subject["username"] = connection
        end
      end
    end

    describe "#[]" do
      before do
        subject["username"] = connection
      end

      context "when passed a known user identifier" do
        it "returns that user's connection" do
          expect(subject["username"].connections.first).to eq(connection)
        end
      end
    end

    describe "#delete" do
      before do
        subject["Juanita"] = connection
      end

      it "deletes the connection from the users hash" do
        subject.delete(connection)
        expect(subject["Juanita"]).to be_a UserManager::MissingConnection
      end

      context "user has exactly one existing connection" do
        it "dispatches websocket_rails.user_disconnected" do
          connection.dispatcher.should_receive(:dispatch) do |dispatch_event|
            # Make sure that we delete the LocalConnection before the event
            # is dispatched
            subject["Juanita"].should be_a UserManager::MissingConnection

            dispatch_event.data[:identifier].should eq("Juanita")
            dispatch_event.is_internal?.should be true
            dispatch_event.name.should eq(:user_disconnected)
          end

          subject.delete(connection)
        end
      end

      context "user has multiple existing connection" do
        before do
          subject["Juanita"] = double('Connection')
        end

        it "doesn't dispatch websocket_rails.user_disconnected" do
          connection.dispatcher.should_not_receive(:dispatch)
          subject.delete(connection)
        end
      end
    end

    describe "#each" do
      before do
        subject['Juanita'] = connection
      end

      context "when synchronization is disabled" do
        before do
          allow(WebsocketRails).to receive(:synchronize?).and_return false
        end

        it "passes each local connection to the given block" do
          subject.each do |conn|
            expect(connection).to eq(conn.connections.first)
          end
        end
      end

      context "when synchronization is enabled" do
        before do
          allow(WebsocketRails).to receive(:synchronize?).and_return true

          user_attr = {name: 'test', email: 'test@test.com'}.to_json
          allow(subject.sync).to receive(:all_remote_users).and_return 'test' => user_attr
        end

        it "passes each remote connection to the given block" do
          subject.each do |conn|
            expect(conn.class).to eq(UserManager::RemoteConnection)
            expect(conn.user.class).to eq(User)
            expect(conn.user.name).to eq('test')
            expect(conn.user.email).to eq('test@test.com')
          end
        end
      end
    end

    describe "#map" do
      before do
        subject['Juanita'] = connection
      end

      context "when synchronization is disabled" do
        before do
          allow(WebsocketRails).to receive(:synchronize?).and_return false
        end

        it "passes each local connection to the given block and collects the results" do
          results = subject.map do |conn|
            [conn, true]
          end
          expect(results.count).to eq(1)
          expect(results[0][0].connections.count).to eq(1)
        end
      end

      context "when synchronization is enabled" do
        before do
          allow(WebsocketRails).to receive(:synchronize?).and_return true

          user_attr = {name: 'test', email: 'test@test.com'}.to_json
          allow(subject.sync).to receive(:all_remote_users).and_return 'test' => user_attr
        end

        it "passes each remote connection to the given block and collects the results" do
          results = subject.map do |conn|
            [conn, true]
          end
          expect(results.count).to eq(1)
          expect(results[0].first.class).to eq(UserManager::RemoteConnection)
        end
      end
    end
  end
end
